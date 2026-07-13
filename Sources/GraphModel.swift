import SwiftUI
import AppKit
import Foundation

/// A node in the graph (a folder or image tile). Position is in graph space.
struct GNode: Identifiable {
    let id: String          // absolute path
    let name: String
    let url: URL
    let isDirectory: Bool
    let count: Int          // immediate subfolder count
    let pictureCount: Int   // immediate image-file count (for the "N pictures" label)
    let depth: Int          // 0 = root, 1 = top-level folders, 2 = their children, …
    let expanded: Bool
    let accent: Color
    var center: CGPoint
    /// true when this node is an image FILE rendered as a thumbnail tile (not a
    /// folder card). Drives culling, async thumbnail load, and lightbox tap.
    let isImage: Bool
    /// Sibling image URLs in the same folder, in display order — handed to the
    /// lightbox so it can build the filmstrip without re-listing the directory.
    let siblingImages: [URL]
    /// Position among this node's parent's children (0 = first/topmost) and how
    /// many siblings share the parent joint. Lets the graph land a child card/tile
    /// at the TIP of its branch in the same staggered order the branch is drawn —
    /// and leave in reverse order on collapse. 0/1 for the root (no parent).
    let siblingIndex: Int
    let siblingCount: Int
}

struct GEdge: Identifiable {
    let id: String
    let from: CGPoint       // parent output port
    let to: CGPoint         // child input port
    let color: Color
    /// Order of this branch among its siblings (0 = first/topmost drawn) and the
    /// sibling total. Drives the "hand-drawn" fan-out: each branch's ink-out is
    /// delayed by its index so limbs draw ONE AFTER ANOTHER from the shared parent
    /// joint, and on collapse the LAST-drawn branch retracts FIRST (reverse stagger).
    let siblingIndex: Int
    let siblingCount: Int
}

struct GraphLayout {
    var nodes: [GNode] = []
    var edges: [GEdge] = []
    var size: CGSize = .init(width: 800, height: 600)
}

/// Builds a tidy left-to-right tree of the opened folder. Wraps a FolderStore for
/// all filesystem access (so the same root-scoping + ordering + ops apply).
@MainActor
final class GraphModel: ObservableObject {
    let fs: FolderStore
    @Published var expanded: Set<String> = []
    @Published var layout = GraphLayout()
    @Published var errorMessage: String?
    private var cache: [String: [FolderItem]] = [:]

    var root: URL { fs.root }
    var rootName: String { fs.root.lastPathComponent }

    init(root: URL) { self.fs = FolderStore(root: root) }

    static let colW: CGFloat = 250      // x gap between depths
    static let rowH: CGFloat = 66       // y gap between leaf slots
    static let nodeW: CGFloat = 196
    static let pad: CGFloat = 90

    // Image-thumbnail grid (rendered to the right of an expanded picture folder).
    static let tile: CGFloat = 120      // thumbnail tile edge
    static let tileGap: CGFloat = 14    // gap between tiles
    static let gridCols = 5             // thumbnails per row
    static let gridStep: CGFloat = tile + tileGap

    func start() {
        if expanded.isEmpty { defaultExpand() } else { rebuild() }
    }

    /// Default open state: show the root and its top-level folders (depth 1), but
    /// stop there — deeper folders stay COLLAPSED until clicked, so a large tree
    /// doesn't explode on open.
    func defaultExpand() {
        var dirs: Set<String> = []
        func walk(_ path: String, _ depth: Int) {
            dirs.insert(path)
            guard depth < 1 else { return }   // root + its immediate children only
            for kid in children(path) where kid.isDirectory && kid.subfolderCount > 0 {
                walk(kid.url.path, depth + 1)
            }
        }
        walk(fs.root.path, 0)
        expanded = dirs
        rebuild()
    }

    /// Expand EVERY folder in the tree (the toolbar "expand all" button).
    func expandAll() {
        var dirs: Set<String> = []
        func walk(_ path: String) {
            dirs.insert(path)
            for kid in children(path) where kid.isDirectory && kid.subfolderCount > 0 {
                walk(kid.url.path)
            }
        }
        walk(fs.root.path)
        expanded = dirs
        rebuild()
    }

    private func children(_ path: String) -> [FolderItem] {
        if let cached = cache[path] { return cached }
        // Folders AND image files become nodes — but only when their parent is
        // expanded (visit() only recurses into expanded dirs), so a picture
        // folder's thumbnails don't exist as nodes until it's clicked. Loose
        // non-image files stay hidden (they'd just be noise in the graph).
        let items = fs.children(of: URL(fileURLWithPath: path)).filter {
            $0.isDirectory || FolderStore.imageExtensions.contains($0.url.pathExtension.lowercased())
        }
        cache[path] = items
        return items
    }

    func toggle(_ node: GNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.id) {
            expanded = expanded.filter { $0 != node.id && !$0.hasPrefix(node.id + "/") }
        } else {
            expanded.insert(node.id)
        }
        rebuild()
    }

    func collapseAll() { expanded = [fs.root.path]; rebuild() }
    func refresh() { cache.removeAll(); rebuild() }

    private func item(from node: GNode) -> FolderItem {
        FolderItem(id: node.id, name: node.name, url: node.url,
                   isDirectory: node.isDirectory, subfolderCount: node.count)
    }
    func rename(_ node: GNode, to newName: String) {
        fs.rename(item(from: node), to: newName); errorMessage = fs.errorMessage
        cache.removeAll(); rebuild()
    }
    func trash(_ node: GNode) {
        fs.trash(item(from: node)); errorMessage = fs.errorMessage
        expanded = expanded.filter { $0 != node.id && !$0.hasPrefix(node.id + "/") }
        cache.removeAll(); rebuild()
    }
    func reveal(_ node: GNode) { fs.revealInFinder(item(from: node)) }

    /// Move a folder node into another folder node's directory — the drag-and-drop
    /// drop handler. Delegates the on-disk move + safety checks (within-root, not
    /// into itself/descendant, destination free) to `FolderStore.move`, then drops
    /// the stale child cache and re-lays the tree so it appears in its new home.
    @discardableResult
    func move(_ node: GNode, into destNode: GNode) -> Bool {
        guard node.depth >= 1, node.isDirectory, destNode.isDirectory else { return false }
        let ok = fs.move(item(from: node), into: destNode.url)
        errorMessage = fs.errorMessage
        if ok {
            // The folder's path changed — forget any expansion under its old path.
            expanded = expanded.filter { $0 != node.id && !$0.hasPrefix(node.id + "/") }
            cache.removeAll()
            rebuild()
        }
        return ok
    }

    // MARK: - Tidy-tree layout

    func rebuild() {
        var nodes: [GNode] = []
        var edges: [GEdge] = []
        var nextLeafY: CGFloat = 0

        func visit(url: URL, name: String, isDir: Bool, count: Int, pics: Int, depth: Int, accent: Color,
                   order: Int, siblingTotal: Int) -> CGPoint {
            let id = url.path
            let isExp = expanded.contains(id)
            let kids = (isDir && isExp) ? children(id) : []

            // A picture folder: its expanded children are all image files. Lay them
            // out as a compact grid to the right instead of one-per-row leaves.
            let imageKids = kids.filter { !$0.isDirectory }
            let isPictureGrid = isDir && isExp && !kids.isEmpty && imageKids.count == kids.count

            let x = Self.pad + CGFloat(depth) * Self.colW
            var childCenters: [(id: String, center: CGPoint)] = []  // (stable child id, port target)
            var y: CGFloat

            if isPictureGrid {
                // Reserve the folder's own row, then lay tiles in a grid beside it.
                let folderY = Self.pad + nextLeafY
                let siblingURLs = imageKids.map { $0.url }
                let gridX = x + Self.nodeW / 2 + Self.pad     // left edge of the grid column
                let rows = (imageKids.count + Self.gridCols - 1) / Self.gridCols
                for (i, kid) in imageKids.enumerated() {
                    let col = i % Self.gridCols
                    let row = i / Self.gridCols
                    let cx = gridX + Self.tile / 2 + CGFloat(col) * Self.gridStep
                    let cy = folderY + Self.tile / 2 + CGFloat(row) * Self.gridStep
                    let center = CGPoint(x: cx, y: cy)
                    // Tiles land in ROW order so each row appears as its branch (one
                    // per row) reaches it — same staggered fan-out as folder children.
                    nodes.append(GNode(id: kid.url.path, name: kid.name, url: kid.url,
                                       isDirectory: false, count: 0, pictureCount: 0,
                                       depth: depth + 1, expanded: false, accent: accent,
                                       center: center, isImage: true, siblingImages: siblingURLs,
                                       siblingIndex: row, siblingCount: rows))
                    if col == 0 { childCenters.append((kid.url.path, center)) }   // one edge per row, to the row's first tile
                }
                let gridHeight = CGFloat(rows) * Self.gridStep
                // Folder sits at the grid's TOP row so the grid drops DOWNWARD from
                // it (opens "there itself") instead of straddling above + below.
                // Advance the leaf cursor past the whole block so nothing overlaps.
                y = folderY + Self.tile / 2
                nextLeafY += max(Self.rowH, gridHeight + Self.tileGap)
            } else if !kids.isEmpty {
                for (i, kid) in kids.enumerated() {
                    // Top-level folders (depth 0's children) each get their own accent
                    // from the palette; deeper folders inherit their branch's color.
                    let kidAccent = depth == 0 ? Self.accent(i) : accent
                    let c = visit(url: kid.url, name: kid.name, isDir: kid.isDirectory,
                                  count: kid.subfolderCount, pics: kid.pictureCount, depth: depth + 1, accent: kidAccent,
                                  order: i, siblingTotal: kids.count)
                    childCenters.append((kid.url.path, c))
                }
                // ANCHOR the node on its subtree TOP (its first child's row), NOT the
                // running average of its children. The DFS leaf cursor gives the first
                // child the exact slot this node occupied while collapsed, so the
                // node's Y is UNCHANGED when it expands — its ancestors never
                // re-center, and only the newly-inserted child branches animate.
                // Expanding a descendant pushes siblings BELOW down (to make room)
                // but leaves the clicked node and every ancestor visually still.
                // (Averaging instead made every ancestor glide on each expand.)
                y = childCenters.first?.center.y ?? (Self.pad + nextLeafY)
            } else {
                y = Self.pad + nextLeafY
                nextLeafY += Self.rowH
            }

            let center = CGPoint(x: x, y: y)
            nodes.append(GNode(id: id, name: name, url: url, isDirectory: isDir, count: count,
                               pictureCount: pics, depth: depth, expanded: isExp, accent: accent,
                               center: center, isImage: false, siblingImages: [],
                               siblingIndex: order, siblingCount: siblingTotal))
            let out = CGPoint(x: center.x + Self.nodeW / 2, y: center.y)
            for (i, child) in childCenters.enumerated() {
                // Folder children connect at their left edge; image tiles at theirs.
                let half = isPictureGrid ? Self.tile / 2 : Self.nodeW / 2
                let inPort = CGPoint(x: child.center.x - half, y: child.center.y)
                // STABLE id (parent→child) so the edge ANIMATES with the nodes when
                // the tree reflows, instead of being torn down and recreated. The
                // (index, count) among siblings drives the staggered branch draw.
                edges.append(GEdge(id: "\(id)->\(child.id)", from: out, to: inPort,
                                   color: accent.opacity(0.55),
                                   siblingIndex: i, siblingCount: childCenters.count))
            }
            return center
        }

        let root = fs.root
        let rootCount = children(root.path).count
        _ = visit(url: root, name: rootName, isDir: true,
                  count: rootCount, pics: 0, depth: 0, accent: Color(white: 0.55),
                  order: 0, siblingTotal: 1)

        let maxX = (nodes.map { $0.center.x }.max() ?? 0) + Self.nodeW / 2 + Self.pad
        let maxY = (nodes.map { $0.center.y }.max() ?? 0) + Self.rowH + Self.pad
        layout = GraphLayout(nodes: nodes, edges: edges,
                             size: CGSize(width: max(maxX, 800), height: max(maxY, 600)))
        errorMessage = fs.errorMessage
    }

    /// A fixed, pleasant palette. Each top-level folder is assigned the next color,
    /// wrapping around — so the graph stays colorful for any folder tree.
    static let palette: [Color] = [
        Color(red: 0.84, green: 0.27, blue: 0.27),  // red
        Color(red: 0.18, green: 0.44, blue: 0.93),  // blue
        Color(red: 0.18, green: 0.62, blue: 0.39),  // green
        Color(red: 0.80, green: 0.52, blue: 0.22),  // orange
        Color(red: 0.55, green: 0.40, blue: 0.78),  // purple
        Color(red: 0.16, green: 0.60, blue: 0.62),  // teal
        Color(red: 0.86, green: 0.40, blue: 0.60),  // pink
        Color(red: 0.36, green: 0.42, blue: 0.85),  // indigo
    ]
    static func accent(_ index: Int) -> Color { palette[index % palette.count] }
}
