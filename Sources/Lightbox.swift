import SwiftUI
import AppKit

/// What the lightbox is showing: the currently-selected image plus every image
/// in the SAME folder (for the filmstrip). Identity = the current image path so
/// the overlay re-presents cleanly when the user opens a different tile.
struct LightboxItem: Identifiable, Equatable {
    let images: [URL]      // all images in the folder, display order
    var current: URL       // the one shown in the main pane
    var id: String { current.path }

    static func == (a: LightboxItem, b: LightboxItem) -> Bool {
        a.current == b.current && a.images == b.images
    }
}

/// Full-screen overlay (a ZStack layer above the graph). Shows the selected image
/// at full quality — the cached thumbnail scaled up first, swapped for the full
/// decode when it arrives — over a dimmed, click-to-dismiss backdrop, with a
/// horizontally-scrollable filmstrip of the folder's images at the bottom.
/// The current image can be zoomed (buttons, pinch, or double-click) and panned.
struct LightboxView: View {
    @State var item: LightboxItem
    let onClose: () -> Void

    @State private var fullImage: NSImage?
    @State private var thumbImage: NSImage?

    // Zoom + pan of the current image. Reset whenever the image changes.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pinchStart: CGFloat?

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 6

    var body: some View {
        ZStack {
            // Dimmed backdrop — opaque enough to fully hide the graph/toolbar behind,
            // and it swallows every click so nothing behind it can move. Tap = dismiss.
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                mainPane
                filmstrip
            }

            // Prev / next arrows, vertically centred — only when there's >1 image.
            if item.images.count > 1 {
                HStack {
                    navArrow("chevron.left") { step(-1) }
                    Spacer()
                    navArrow("chevron.right") { step(1) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 108)   // sit above the filmstrip
            }

            // Top chrome: zoom controls (left) + close (right). Declared LAST so it is
            // always in front of the image — the close button is never covered.
            VStack {
                HStack(alignment: .top) {
                    zoomControls
                    Spacer()
                    closeButton
                }
                .padding(16)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the window
        .onAppear { load() }
        .onChange(of: item.current) { _ in resetZoom(); load() }
        // Esc dismisses; ← / → step images; + / - / 0 zoom the current image.
        .background(KeyCatcher(onEsc: onClose, onLeft: { step(-1) }, onRight: { step(1) },
                               onZoomIn: { setZoom(zoom + 0.5) },
                               onZoomOut: { setZoom(zoom - 0.5) },
                               onReset: { setZoom(1) }))
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)   // Esc dismisses
        .help("Close (Esc)")
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            ctlButton("minus.magnifyingglass") { setZoom(zoom - 0.5) }
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit()).foregroundColor(.white)
                .frame(width: 46)
            ctlButton("plus.magnifyingglass") { setZoom(zoom + 0.5) }
            if zoom != 1 {
                ctlButton("arrow.up.left.and.down.right.magnifyingglass") { setZoom(1) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.16)))
    }

    private func ctlButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navArrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Zoom / pan

    private func setZoom(_ z: CGFloat) {
        let clamped = min(max(z, minZoom), maxZoom)
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = clamped
            if clamped <= 1 { offset = .zero; lastOffset = .zero }
        }
    }
    private func resetZoom() { zoom = 1; offset = .zero; lastOffset = .zero; pinchStart = nil }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { m in
                if pinchStart == nil { pinchStart = zoom }
                zoom = min(max((pinchStart ?? zoom) * m, minZoom), maxZoom)
            }
            .onEnded { _ in
                pinchStart = nil
                if zoom <= 1 { offset = .zero; lastOffset = .zero }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { g in
                offset = CGSize(width: lastOffset.width + g.translation.width,
                                height: lastOffset.height + g.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    /// Move to the previous/next image in the folder (wraps around).
    private func step(_ delta: Int) {
        let imgs = item.images
        guard imgs.count > 1, let idx = imgs.firstIndex(of: item.current) else { return }
        item.current = imgs[(idx + delta + imgs.count) % imgs.count]
    }

    // MARK: - Main image pane

    private var mainPane: some View {
        GeometryReader { geo in
            ZStack {
                if let img = fullImage ?? thumbImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom)
                        .offset(offset)
                        // Blur the thumbnail a touch while the full image loads so the
                        // upscale doesn't look harsh.
                        .blur(radius: fullImage == nil ? 1.5 : 0)
                        // Pinch to zoom; drag to pan once zoomed; double-click toggles.
                        .gesture(magnifyGesture)
                        .simultaneousGesture(zoom > 1 ? panGesture : nil)
                        .onTapGesture(count: 2) { setZoom(zoom > 1 ? 1 : 2.5) }
                } else {
                    ProgressView().scaleEffect(1.4).tint(.white)
                }
                if fullImage == nil && thumbImage != nil {
                    VStack { Spacer(); HStack { Spacer()
                        ProgressView().tint(.white).padding(10)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                            .padding(14) } }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(item.images, id: \.path) { url in
                        FilmstripThumb(url: url, isCurrent: url == item.current)
                            .id(url.path)
                            .onTapGesture { item.current = url }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(Color.black.opacity(0.35))
            .onAppear { proxy.scrollTo(item.current.path, anchor: .center) }
            .onChange(of: item.current) { cur in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(cur.path, anchor: .center) }
            }
        }
        .frame(height: 108)
    }

    // MARK: - Loading

    private func load() {
        // Reuse the cached thumbnail as an instant low-res preview; load full async.
        thumbImage = ThumbnailCache.shared.cached(item.current)
        fullImage = nil
        let target = item.current
        ThumbnailCache.shared.loadFull(target) { img in
            // Ignore a stale completion if the user already switched images.
            if target == item.current { fullImage = img }
        }
    }
}

/// One filmstrip cell — reuses the shared thumbnail cache (never re-decodes).
private struct FilmstripThumb: View {
    let url: URL
    let isCurrent: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2))
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isCurrent ? Color.white : Color.white.opacity(0.18),
                    lineWidth: isCurrent ? 3 : 1))
        .scaleEffect(isCurrent ? 1.0 : 0.94)
        .onAppear {
            if image == nil {
                ThumbnailCache.shared.thumbnail(for: url) { image = $0 }
            }
        }
    }
}

/// Tiny NSView shim for keyboard control of the lightbox: Esc dismisses, ←/→ step
/// through images, + / - zoom, 0 resets. (keyboardShortcut needs a focused responder;
/// this is a reliable fallback that grabs first responder and listens for keyCodes.)
private struct KeyCatcher: NSViewRepresentable {
    let onEsc: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onReset: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.bind(onEsc, onLeft, onRight, onZoomIn, onZoomOut, onReset)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyView)?.bind(onEsc, onLeft, onRight, onZoomIn, onZoomOut, onReset)
    }
    final class KeyView: NSView {
        var onEsc: (() -> Void)?
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onZoomIn: (() -> Void)?
        var onZoomOut: (() -> Void)?
        var onReset: (() -> Void)?
        func bind(_ esc: @escaping () -> Void, _ left: @escaping () -> Void, _ right: @escaping () -> Void,
                  _ zin: @escaping () -> Void, _ zout: @escaping () -> Void, _ reset: @escaping () -> Void) {
            onEsc = esc; onLeft = left; onRight = right; onZoomIn = zin; onZoomOut = zout; onReset = reset
        }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53:  onEsc?()      // Esc
            case 123: onLeft?()     // ←
            case 124: onRight?()    // →
            case 24, 69:  onZoomIn?()   // = / +  (and keypad +)
            case 27, 78:  onZoomOut?()  // -      (and keypad -)
            case 29, 82:  onReset?()    // 0      (and keypad 0)
            default:  super.keyDown(with: event)
            }
        }
    }
}
