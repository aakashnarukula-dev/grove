import SwiftUI
import AppKit

struct GraphView: View {
    @EnvironmentObject var library: Library
    @StateObject private var model: GraphModel
    @Binding var useGraph: Bool

    init(root: URL, useGraph: Binding<Bool>) {
        _model = StateObject(wrappedValue: GraphModel(root: root))
        _useGraph = useGraph
    }

    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .init(width: 40, height: 40)
    @State private var lastDrag: CGSize = .zero         // running drag translation (for deltas)
    @State private var cursorLoc: CGPoint = .zero       // pointer in viewport coords
    @State private var pinchStartScale: CGFloat?        // scale at the start of a pinch
    @State private var viewportSize: CGSize = .zero
    @State private var renameTarget: GNode?
    @State private var deleteTarget: GNode?
    @State private var scrollMonitor: Any?
    @State private var lightbox: LightboxItem?

    // Drag-and-drop of a FOLDER node onto another FOLDER node (to move it there).
    // `dragNodeID` is the folder being carried; `dropTargetID` is the highlighted
    // folder currently under the cursor (nil = no valid target). `dragTranslation`
    // is the in-progress local-space drag offset used to render the "lifted" node.
    @State private var dragNodeID: String?
    @State private var dropTargetID: String?
    @State private var dragTranslation: CGSize = .zero

    /// Below this scale (zoomed far out) image tiles render as cheap placeholder
    /// rects instead of decoded thumbnails (LOD — saves load + GPU work).
    private let thumbLODThreshold: CGFloat = 0.5

    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            GraphBackground()
            canvas
        }
        // Pin the content top-leading (not centered) so it never shifts under the
        // toolbar when the zoomed canvas grows larger than the window — this also
        // keeps the pan/zoom math (screen = content · scale + pan) consistent.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.09))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { viewportSize = g.size }
                .onChange(of: g.size) { viewportSize = $0; clampPan() }
        })
        .contentShape(Rectangle())
        // Pan + pinch live on the FULL viewport (not the canvas) so they work over
        // empty space too — node taps still win (tap vs. drag disambiguation).
        .gesture(
            DragGesture()
                .onChanged { g in
                    pan.width += g.translation.width - lastDrag.width
                    pan.height += g.translation.height - lastDrag.height
                    lastDrag = g.translation
                    clampPan()   // can't fling the nodes off-screen
                }
                .onEnded { _ in lastDrag = .zero }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { m in
                    if pinchStartScale == nil { pinchStartScale = scale }
                    let amplified = CGFloat(pow(Double(m), 1.6))   // a touch more sensitive
                    zoom(to: (pinchStartScale ?? scale) * amplified, at: cursorLoc)
                }
                .onEnded { _ in pinchStartScale = nil }
        )
        .onContinuousHover { phase in
            if case .active(let loc) = phase { cursorLoc = loc }
        }
        .clipped()
        // Fixed chrome, layered on the WINDOW-sized container (after clipping) so it
        // stays put no matter how large or offset the zoomed canvas becomes.
        .overlay(alignment: .top) { topBar }
        .overlay {
            if let lb = lightbox {
                LightboxView(item: lb) { lightbox = nil }
                    .transition(.opacity)
            }
        }
        .onAppear {
            model.start()
            if scrollMonitor == nil {
                // Two-finger trackpad swipe pans the canvas (same direction as a
                // click-drag). Pinch-to-zoom stays on the separate magnify gesture.
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    pan.width += event.scrollingDeltaX
                    pan.height += event.scrollingDeltaY
                    clampPan()
                    return event
                }
            }
        }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
        .onReceive(tick) { _ in if renameTarget == nil, deleteTarget == nil { model.refresh() } }
        .sheet(item: $renameTarget) { node in
            RenameSheet(originalName: node.name) { model.rename(node, to: $0); renameTarget = nil }
                onCancel: { renameTarget = nil }
        }
        .confirmationDialog("Move “\(deleteTarget?.name ?? "")” to Trash?",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            presenting: deleteTarget) { node in
            Button("Move to Trash", role: .destructive) { model.trash(node); deleteTarget = nil }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in Text("Goes to the Trash (recoverable). Scoped to the opened folder.") }
    }

    // MARK: - Canvas

    private var canvas: some View {
        let layout = model.layout
        let visible = visibleContentRect()
        return ZStack {
            edgesLayer(layout)
            nodesLayer(layout)
            tilesLayer(layout, visible: visible)
        }
        // Bake the zoom into the rendering geometry (frame/positions/sizes/fonts all
        // multiplied by `scale`) instead of a .scaleEffect transform — that rasterized
        // at 1× then upscaled, blurring text > 1×. Now SwiftUI re-renders text at the
        // scaled font size, so it stays vector-sharp at ANY zoom.
        .frame(width: layout.size.width * scale, height: layout.size.height * scale)
        .offset(x: pan.width, y: pan.height)
    }

    // MARK: - Canvas layers (split out so the type-checker stays fast)

    /// Connector threads — animatable shapes (stable ids) so they glide with nodes.
    @ViewBuilder
    private func edgesLayer(_ layout: GraphLayout) -> some View {
        ForEach(layout.edges) { e in
            EdgeShape(from: e.from, to: e.to, scale: scale)
                .stroke(e.color, style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))
                .transition(.opacity)   // grid threads fade in/out; tree threads glide
            Circle().fill(e.color).frame(width: 6 * scale, height: 6 * scale)
                .position(x: e.to.x * scale, y: e.to.y * scale)
                .transition(.opacity)
        }
        .frame(width: layout.size.width * scale, height: layout.size.height * scale)
    }

    /// Folder/text cards (the tree). Opening a picture grid reflows the tree and,
    /// because the toggle is animated, every other node glides — a smooth push.
    @ViewBuilder
    private func nodesLayer(_ layout: GraphLayout) -> some View {
        ForEach(layout.nodes.filter { !$0.isImage }) { node in
            let isDragging = dragNodeID == node.id
            let isDropTarget = dropTargetID == node.id
            NodeCard(node: node,
                     isOpen: node.expanded,
                     isDragging: isDragging,
                     isDropTarget: isDropTarget,
                     scale: scale,
                     onToggle: { onNodeTap(node) },
                     onRename: { renameTarget = node },
                     onReveal: { model.reveal(node) },
                     onTrash: { deleteTarget = node },
                     onDragChanged: { translation in nodeDragChanged(node, translation: translation) },
                     onDragEnded: { nodeDragEnded(node) })
                // While carried, offset the node by the drag so it tracks the cursor;
                // lift it above siblings + edges via zIndex. With the .scaleEffect
                // removed, this offset is now screen points directly — no /scale.
                .offset(isDragging ? dragTranslation : .zero)
                .zIndex(isDragging ? 100 : 0)
                .position(x: node.center.x * scale, y: node.center.y * scale)
        }
    }

    // MARK: - Folder drag-and-drop (long-press → drag onto another folder)

    /// Live drag of a FOLDER node. Tracks the lifted offset and figures out which
    /// folder (if any) the cursor is over so we can highlight it as the drop target.
    private func nodeDragChanged(_ node: GNode, translation: CGSize) {
        guard node.depth >= 1, node.isDirectory else { return }
        dragNodeID = node.id
        dragTranslation = translation
        dropTargetID = folderUnderCursor(draggedNode: node, translation: translation)?.id
    }

    /// Release. If the cursor is over a DIFFERENT, valid folder, move the dragged
    /// folder into it on disk. Otherwise it snaps back (we just clear the drag
    /// state — the node returns to its laid-out position).
    private func nodeDragEnded(_ node: GNode) {
        defer { dragNodeID = nil; dropTargetID = nil; dragTranslation = .zero }
        guard node.depth >= 1, node.isDirectory,
              let dest = folderUnderCursor(draggedNode: node, translation: dragTranslation)
        else { return }
        withAnimation(.easeInOut(duration: 0.3)) { _ = model.move(node, into: dest) }
    }

    /// Hit-test the cursor (the dragged node's center + the scale-corrected drag
    /// translation, in CONTENT space) against every FOLDER node's card rect.
    /// Returns a valid drop target, or nil. Excludes the dragged node itself, any
    /// folder INSIDE it (can't move a folder into its own descendant), and the
    /// folder's CURRENT parent (that would be a no-op).
    private func folderUnderCursor(draggedNode: GNode, translation: CGSize) -> GNode? {
        // The node moves in screen space by `translation`; in content space that is
        // translation / scale. Add to the node's laid-out center to get the cursor
        // point in content coordinates (same space the layout centers live in).
        let cursor = CGPoint(x: draggedNode.center.x + translation.width / scale,
                             y: draggedNode.center.y + translation.height / scale)
        let half = GraphModel.nodeW / 2
        let cardH: CGFloat = 48   // approx NodeCard height (2 stacked rows)
        let currentParent = draggedNode.url.deletingLastPathComponent().standardizedFileURL.path
        var hit: GNode?
        for n in model.layout.nodes where n.isDirectory && !n.isImage {
            if n.id == draggedNode.id { continue }                       // itself
            if n.id.hasPrefix(draggedNode.id + "/") { continue }         // inside the dragged folder
            if n.url.standardizedFileURL.path == currentParent { continue } // already its parent
            let rect = CGRect(x: n.center.x - half, y: n.center.y - cardH / 2,
                              width: GraphModel.nodeW, height: cardH)
            if rect.contains(cursor) { hit = n }   // last (topmost-drawn) match wins
        }
        return hit
    }

    /// In-tree image tiles, view-level culled (off-screen ones cost nothing).
    @ViewBuilder
    private func tilesLayer(_ layout: GraphLayout, visible: CGRect) -> some View {
        ForEach(layout.nodes.filter { $0.isImage && pointVisible($0.center.x, $0.center.y, visible) }) { node in
            ImageTile(url: node.url, accent: node.accent,
                      shouldLoad: scale >= thumbLODThreshold,
                      scale: scale,
                      onOpen: { openLightbox(node.siblingImages, current: node.url) })
                .position(x: node.center.x * scale, y: node.center.y * scale)
                // Fade in on open / out on close — same transition both ways.
                .transition(.opacity)
        }
    }

    /// Zoom toward a viewport point so the content under it stays put — "zoom into
    /// that region" rather than zooming from a corner/centre. The transform is
    /// screen(c) = c * scale + pan (top-leading anchor), so we recompute pan to
    /// pin the content point currently under `p`.
    private func zoom(to newScale: CGFloat, at p: CGPoint) {
        let s = min(max(newScale, 0.35), 2.6)
        let c = CGPoint(x: (p.x - pan.width) / max(scale, 0.0001),
                        y: (p.y - pan.height) / max(scale, 0.0001))
        pan = CGSize(width: p.x - c.x * s, height: p.y - c.y * s)
        scale = s
        clampPan()
    }

    /// Keep the graph from being dragged/zoomed completely off-screen: at least
    /// ~5% of the content's bounding box (and never less than one node) stays
    /// visible on each axis. Called after every pan/zoom change.
    private func clampPan() {
        guard viewportSize != .zero else { return }
        let nodes = model.layout.nodes
        guard !nodes.isEmpty else { return }
        let xs = nodes.map(\.center.x), ys = nodes.map(\.center.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let cw = (maxX - minX) * scale, ch = (maxY - minY) * scale
        let keepX = max(GraphModel.nodeW * scale, cw * 0.05)   // ≥5% (and ≥ a node) on-screen
        let keepY = max(GraphModel.tile * scale, ch * 0.05)
        let loX = keepX - maxX * scale                         // content right edge ≥ keepX
        let hiX = viewportSize.width - keepX - minX * scale    // content left edge ≤ width-keepX
        let loY = keepY - maxY * scale
        let hiY = viewportSize.height - keepY - minY * scale
        pan.width = min(max(pan.width, min(loX, hiX)), max(loX, hiX))
        pan.height = min(max(pan.height, min(loY, hiY)), max(loY, hiY))
    }

    // MARK: - Viewport culling

    /// The visible region of the canvas, in CONTENT (graph) coordinates. The
    /// transform is screen = content * scale + pan (top-leading anchor), so the
    /// inverse maps the viewport's [0, viewportSize] back to content space. We
    /// inflate by ~1.5 screens of margin so panning reveals already-loaded tiles
    /// (no pop-in). Pure arithmetic — cheap to recompute every pan/zoom frame.
    private func visibleContentRect() -> CGRect {
        let s = max(scale, 0.0001)
        let px = pan.width
        let py = pan.height
        let originX = -px / s
        let originY = -py / s
        let w = viewportSize.width / s
        let h = viewportSize.height / s
        let mx = w * 0.6, my = h * 0.6     // inflate margin (~0.6 screen each side)
        return CGRect(x: originX - mx, y: originY - my, width: w + 2 * mx, height: h + 2 * my)
    }

    private func openLightbox(_ images: [URL], current: URL) {
        withAnimation(.easeInOut(duration: 0.18)) {
            lightbox = LightboxItem(images: images, current: current)
        }
    }

    private func isPictureFolder(_ node: GNode) -> Bool {
        node.isDirectory && node.count == 0 && node.pictureCount > 0
    }

    /// Tap routing. Opening a PICTURE folder keeps the folder PINNED in place and
    /// only nudges the view if the grid would be off-screen (scroll-into-view — it
    /// won't drag the workflow left when there's room on the right). Closing (or
    /// any other folder) just pins the clicked node. All animated.
    private func onNodeTap(_ node: GNode) {
        guard isPictureFolder(node) else { toggleAnchored(node); return }
        let opening = !node.expanded
        let oldCenter = node.center
        withAnimation(.easeInOut(duration: 0.35)) {
            model.toggle(node)
            anchorPan(id: node.id, oldCenter: oldCenter)   // folder stays exactly put
            if opening { revealGrid(folderID: node.id) }   // nudge into view ONLY if needed
            clampPan()
        }
    }

    /// Pin a node: offset pan by its position delta so it stays put across a reflow.
    private func anchorPan(id: String, oldCenter: CGPoint) {
        if let now = model.layout.nodes.first(where: { $0.id == id }) {
            pan.width -= (now.center.x - oldCenter.x) * scale
            pan.height -= (now.center.y - oldCenter.y) * scale
        }
    }

    /// Pan the MINIMUM to bring the just-opened grid into view. If it already fits
    /// (e.g. in the empty space to the right) this does NOTHING — no left push, no
    /// recenter. If it overflows, nudge just enough, aligning the top/left when the
    /// grid is bigger than the viewport so the pictures read from there.
    private func revealGrid(folderID: String) {
        let tiles = model.layout.nodes.filter {
            $0.isImage && $0.url.deletingLastPathComponent().path == folderID
        }
        guard !tiles.isEmpty, viewportSize != .zero else { return }
        let half = GraphModel.tile / 2
        let xs = tiles.map(\.center.x), ys = tiles.map(\.center.y)
        // grid rect in SCREEN coords: content * scale + pan
        let left = (xs.min()! - half) * scale + pan.width
        let right = (xs.max()! + half) * scale + pan.width
        let top = (ys.min()! - half) * scale + pan.height
        let bottom = (ys.max()! + half) * scale + pan.height
        let m: CGFloat = 28          // breathing room from edges
        let topInset: CGFloat = 56   // keep clear of the toolbar

        var dx: CGFloat = 0
        if right - left > viewportSize.width - 2 * m { dx = m - left }                       // wider than screen → show its left
        else if right > viewportSize.width - m { dx = (viewportSize.width - m) - right }     // off the right → nudge in
        else if left < m { dx = m - left }                                                  // off the left → nudge in

        var dy: CGFloat = 0
        if bottom - top > viewportSize.height - topInset - m { dy = topInset - top }         // taller than screen → show its top
        else if bottom > viewportSize.height - m { dy = (viewportSize.height - m) - bottom } // off the bottom → nudge up
        else if top < topInset { dy = topInset - top }                                       // under the toolbar → nudge down

        pan.width += dx
        pan.height += dy
    }

    /// Open/close a (non-picture) folder, pinned + animated.
    private func toggleAnchored(_ node: GNode) {
        let oldCenter = node.center
        withAnimation(.easeInOut(duration: 0.28)) {
            model.toggle(node)
            anchorPan(id: node.id, oldCenter: oldCenter)
            clampPan()
        }
    }

    private func pointVisible(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> Bool {
        if rect.isEmpty { return true }
        let half = GraphModel.tile / 2
        return CGRect(x: x - half, y: y - half, width: GraphModel.tile, height: GraphModel.tile).intersects(rect)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Label(model.rootName, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            if let err = model.errorMessage {
                Text(err).font(.caption).foregroundColor(.orange).lineLimit(1)
            }
            Spacer()
            chip("minus.magnifyingglass") { zoom(to: scale - 0.15, at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)) }
            Text("\(Int(scale * 100))%").font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.7)).frame(width: 38)
            chip("plus.magnifyingglass") { zoom(to: scale + 0.15, at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)) }
            chip("arrow.counterclockwise") { scale = 1; pan = .init(width: 40, height: 40) }
            chip("rectangle.expand.vertical") { model.expandAll() }
            chip("rectangle.compress.vertical") { model.collapseAll() }
            chip("arrow.clockwise") { model.refresh() }
            chip("folder") { library.openPanel() }
            Button { useGraph = false } label: {
                Label("Finder view", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private func chip(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain).foregroundColor(.white.opacity(0.85))
            .frame(width: 26, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.10)))
    }
}

// MARK: - Node card

struct NodeCard: View {
    let node: GNode
    let isOpen: Bool
    /// This folder card is currently being carried by a long-press drag.
    var isDragging: Bool = false
    /// This folder is the highlighted drop target under the cursor.
    var isDropTarget: Bool = false
    /// Zoom level — baked into every font/size/padding so text stays vector-sharp.
    var scale: CGFloat = 1
    let onToggle: () -> Void
    let onRename: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void
    /// Live drag translation (screen space) of a carried FOLDER node.
    var onDragChanged: (CGSize) -> Void = { _ in }
    /// Drag released — caller decides whether to move or snap back.
    var onDragEnded: () -> Void = {}

    /// Any folder EXCEPT the root can be renamed, trashed, and dragged to move.
    private var isMovable: Bool { node.depth >= 1 && node.isDirectory }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6 * scale) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 11 * scale)).foregroundColor(.white)
                Text(node.name).font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(.white).lineLimit(1)
            }
            .padding(.horizontal, 9 * scale).padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(node.accent)

            HStack(spacing: 6 * scale) {
                Text(subtitle).font(.system(size: 10 * scale)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 4 * scale)
                if node.isDirectory {
                    Image(systemName: isOpen ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 12 * scale)).foregroundColor(node.accent)
                }
            }
            .padding(.horizontal, 9 * scale).padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.17))
        }
        .frame(width: GraphModel.nodeW * scale)
        .clipShape(RoundedRectangle(cornerRadius: 9 * scale))
        .overlay(RoundedRectangle(cornerRadius: 9 * scale).stroke(node.accent.opacity(0.85), lineWidth: 1.4 * scale))
        // Drop-target ring: glows on the folder under a dragged node.
        .overlay(
            RoundedRectangle(cornerRadius: 9 * scale)
                .stroke(Color.green, lineWidth: 3 * scale)
                .opacity(isDropTarget ? 1 : 0)
        )
        // Lifted look while carried: bigger shadow + a slight scale-up.
        .shadow(color: .black.opacity(isDragging ? 0.7 : 0.45),
                radius: (isDragging ? 16 : 6) * scale, x: 0, y: (isDragging ? 10 : 3) * scale)
        .scaleEffect(isDragging ? 1.06 : 1)
        .overlay(alignment: .leading) {
            Circle().fill(node.accent).frame(width: 8 * scale, height: 8 * scale)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1 * scale)).offset(x: -4 * scale)
        }
        .overlay(alignment: .trailing) {
            if node.isDirectory {
                Circle().fill(isOpen ? node.accent : Color(white: 0.3))
                    .frame(width: 8 * scale, height: 8 * scale)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1 * scale)).offset(x: 4 * scale)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        // Long-press → drag, on movable folders ONLY. The DragGesture is SEQUENCED
        // AFTER a 0.35s LongPressGesture, so a quick/plain drag never engages here
        // — it falls through to the outer ZStack's pan gesture. Only a press-and-
        // hold "picks up" the folder; pinch-zoom (a separate gesture) is unaffected.
        .gesture(isMovable ? nodeDragGesture : nil)
        .contextMenu {
            if node.isDirectory { Button(isOpen ? "Collapse" : "Expand") { onToggle() }; Divider() }
            if isMovable { Button("Rename…") { onRename() } }
            Button("Reveal in Finder") { onReveal() }
            // DELETE is offered for any folder EXCEPT the root.
            if isMovable {
                Divider()
                Button("Move to Trash") { onTrash() }
            }
        }
    }

    /// Long-press (0.35s) then drag — picks up a folder card. The LongPressGesture
    /// must complete first, so a normal drag still pans the canvas (outer gesture).
    private var nodeDragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                // .second(true, drag?) means the long press fired and we may now be
                // dragging; report the live translation so the view lifts + tracks.
                if case .second(true, let drag?) = value {
                    onDragChanged(drag.translation)
                }
            }
            .onEnded { _ in onDragEnded() }
    }

    private var subtitle: String {
        if !node.isDirectory { return node.url.pathExtension.isEmpty ? "file" : node.url.pathExtension.uppercased() }
        let n = node.count
        if n > 0 { return "\(n) folder\(n == 1 ? "" : "s")" }
        let p = node.pictureCount
        if p > 0 { return "\(p) picture\(p == 1 ? "" : "s")" }
        return "empty"
    }
}

// MARK: - Image thumbnail tile

/// A single image rendered as a square thumbnail tile in a picture-folder grid.
/// When `shouldLoad` is false (off-screen or zoomed far out) it renders a cheap
/// placeholder rect and loads NOTHING. When it becomes visible it async-loads the
/// downsampled thumbnail from the shared cache, showing a spinner placeholder
/// until ready. The cached NSImage is GPU-scaled by the canvas's scaleEffect —
/// it is never re-decoded on zoom.
struct ImageTile: View {
    let url: URL
    let accent: Color
    let shouldLoad: Bool
    /// Zoom level — baked into the tile edge + internal metrics so it renders sharp.
    var scale: CGFloat = 1
    let onOpen: () -> Void

    @State private var image: NSImage?

    /// Tile edge in screen points (graph-space GraphModel.tile × current zoom).
    private var edge: CGFloat { GraphModel.tile * scale }

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: edge, height: edge)
                    .clipped()
            } else {
                placeholder
            }
        }
        .frame(width: edge, height: edge)
        .clipShape(RoundedRectangle(cornerRadius: 8 * scale))
        .overlay(RoundedRectangle(cornerRadius: 8 * scale)
            .stroke(accent.opacity(image != nil ? 0.85 : 0.4), lineWidth: 1.2 * scale))
        .shadow(color: .black.opacity(0.4), radius: 4 * scale, x: 0, y: 2 * scale)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onChange(of: shouldLoad) { load in if load { loadIfNeeded() } }
        .onAppear { if shouldLoad { loadIfNeeded() } }
        .help(url.lastPathComponent)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8 * scale).fill(Color(white: 0.16))
            if shouldLoad {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22 * scale))
                    .foregroundColor(accent.opacity(0.5))
            }
        }
        .frame(width: edge, height: edge)
    }

    private func loadIfNeeded() {
        guard image == nil else { return }
        // Instant if already cached; otherwise off-main decode then publishes.
        if let hit = ThumbnailCache.shared.cached(url) {
            image = hit
        } else {
            ThumbnailCache.shared.thumbnail(for: url) { img in
                self.image = img
            }
        }
    }
}

// MARK: - Edge (animatable connector)

/// A curved parent→child connector whose endpoints ANIMATE (via animatableData),
/// so threads glide with the nodes when the tree reflows instead of snapping.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    /// Zoom level. animatableData interpolates the UNSCALED endpoints (so edges glide
    /// when nodes move); the path multiplies them by `scale` to render in screen space.
    var scale: CGFloat = 1

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
        set {
            from = CGPoint(x: newValue.first.first, y: newValue.first.second)
            to = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        // Scale the (animated, unscaled) endpoints into screen space here.
        let f = CGPoint(x: from.x * scale, y: from.y * scale)
        let t = CGPoint(x: to.x * scale, y: to.y * scale)
        var p = Path()
        p.move(to: f)
        let dx = max(45 * scale, (t.x - f.x) * 0.5)
        p.addCurve(to: t,
                   control1: CGPoint(x: f.x + dx, y: f.y),
                   control2: CGPoint(x: t.x - dx, y: t.y))
        return p
    }
}

// MARK: - Dotted background

struct GraphBackground: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.09)))
            let gap: CGFloat = 28
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)),
                             with: .color(Color(white: 0.20)))
                    x += gap
                }
                y += gap
            }
        }
        .allowsHitTesting(false)
    }
}
