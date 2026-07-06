import Foundation
import AppKit
import SwiftUI

/// One folder/file row shown in the grid or list.
struct FolderItem: Identifiable, Hashable {
    let id: String          // absolute path — stable identity across reloads
    let name: String
    let url: URL
    let isDirectory: Bool
    let subfolderCount: Int  // number of immediate SUBFOLDERS (directories) inside
    var pictureCount: Int = 0 // immediate image files inside (for the "N pictures" label)

    static func == (a: FolderItem, b: FolderItem) -> Bool {
        a.id == b.id && a.subfolderCount == b.subfolderCount && a.pictureCount == b.pictureCount
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Reads/writes ONLY the folder tree rooted at `root` (the folder the user opened).
/// Every path is checked to be inside `root` before any operation — nothing else
/// on disk is ever touched. Each store is bound to one root for its lifetime; open
/// a different folder and a fresh store is created (see `RootView`).
@MainActor
final class FolderStore: ObservableObject {

    /// The single root this store instance is allowed to operate on.
    let root: URL

    // Linear navigation history (browser-style back/forward). history[0] == root.
    @Published var history: [URL]
    @Published var historyIndex: Int = 0
    @Published var items: [FolderItem] = []
    @Published var errorMessage: String?
    @Published var selection: String?       // selected item id (path)

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.history = [root.standardizedFileURL]
    }

    var currentURL: URL { history.indices.contains(historyIndex) ? history[historyIndex] : root }
    var isAtRoot: Bool { currentURL.standardizedFileURL == root.standardizedFileURL }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    /// Breadcrumb root → current, derived from the path. Each crumb carries its URL.
    var breadcrumbs: [(label: String, url: URL)] {
        var crumbs: [(String, URL)] = [(root.lastPathComponent, root)]
        let rootPath = root.standardizedFileURL.path
        let curPath = currentURL.standardizedFileURL.path
        if curPath.hasPrefix(rootPath + "/") {
            var acc = root
            for comp in curPath.dropFirst(rootPath.count + 1).split(separator: "/") {
                acc = acc.appendingPathComponent(String(comp))
                crumbs.append((String(comp), acc))
            }
        }
        return crumbs
    }

    // MARK: - Safety

    func isWithinRoot(_ url: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == r || p.hasPrefix(r + "/")
    }

    // MARK: - Reading

    func load() {
        let dir = currentURL
        guard isWithinRoot(dir) else {
            items = []; errorMessage = "Refused: target is outside the opened folder."
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            items = []
            errorMessage = isAtRoot ? "Folder not found:\n\(dir.path)" : "This folder no longer exists."
            return
        }
        do {
            let contents = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            var result: [FolderItem] = []
            for url in contents {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let c = isDir ? Self.counts(url) : (subfolders: 0, pictures: 0)
                result.append(FolderItem(
                    id: url.path,
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: isDir,
                    subfolderCount: c.subfolders,
                    pictureCount: c.pictures))
            }
            items = sortItems(result)
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    /// Best-effort listing used by the column browser (one column per folder).
    /// Same ordering rules as `load()`; errors just yield an empty column.
    func children(of dir: URL) -> [FolderItem] {
        guard isWithinRoot(dir),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [FolderItem] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let c = isDir ? Self.counts(url) : (subfolders: 0, pictures: 0)
            result.append(FolderItem(
                id: url.path, name: url.lastPathComponent, url: url,
                isDirectory: isDir, subfolderCount: c.subfolders, pictureCount: c.pictures))
        }
        return sortItems(result)
    }

    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "webp", "heic", "heif", "bmp", "tiff", "tif", "gif"]

    /// One scan → (immediate subfolder count, immediate image-file count).
    static func counts(_ url: URL) -> (subfolders: Int, pictures: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return (0, 0) }
        var sub = 0, pics = 0
        for u in entries {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { sub += 1 }
            else if imageExtensions.contains(u.pathExtension.lowercased()) { pics += 1 }
        }
        return (sub, pics)
    }

    /// Finder-style ordering: folders first, then natural-sorted by name.
    private func sortItems(_ items: [FolderItem]) -> [FolderItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Navigation (browser-style history)

    func open(_ item: FolderItem) {
        guard item.isDirectory else { return }
        navigate(to: item.url)
    }

    /// Go to a folder, pushing it onto history (truncates any forward entries).
    func navigate(to url: URL) {
        guard isWithinRoot(url), url.standardizedFileURL != currentURL.standardizedFileURL else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(url)
        historyIndex = history.count - 1
        selection = nil
        load()
    }

    func goBack() { guard canGoBack else { return }; historyIndex -= 1; selection = nil; load() }
    func goForward() { guard canGoForward else { return }; historyIndex += 1; selection = nil; load() }
    func goToBreadcrumb(_ url: URL) { navigate(to: url) }

    // MARK: - Writing (all scoped to root)

    func rename(_ item: FolderItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), isWithinRoot(item.url) else {
            errorMessage = "Invalid name."; return
        }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard isWithinRoot(dest) else { return }
        if FileManager.default.fileExists(atPath: dest.path) {
            errorMessage = "“\(name)” already exists here."; return
        }
        do { try FileManager.default.moveItem(at: item.url, to: dest); load() }
        catch { errorMessage = "Rename failed: \(error.localizedDescription)" }
    }

    /// Delete = move to Trash (reversible), never a permanent unlink.
    func trash(_ item: FolderItem) {
        guard isWithinRoot(item.url) else { return }
        do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); load() }
        catch { errorMessage = "Move to Trash failed: \(error.localizedDescription)" }
    }

    func revealInFinder(_ item: FolderItem) {
        guard isWithinRoot(item.url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Move an item into another directory (used by drag-and-drop of a folder onto
    /// another folder). Safety: BOTH the source AND the destination directory must
    /// be inside the opened root; the computed destination (`destDir/<name>`) must
    /// not already exist; a folder can't be moved into itself or a descendant; uses
    /// a reversible `moveItem` (no permanent delete). Returns whether it succeeded.
    @discardableResult
    func move(_ item: FolderItem, into destDir: URL) -> Bool {
        guard isWithinRoot(item.url), isWithinRoot(destDir) else {
            errorMessage = "Refused: move target is outside the opened folder."
            return false
        }
        // Can't drop a folder into itself or one of its own descendants.
        let srcPath = item.url.standardizedFileURL.path
        let dstPath = destDir.standardizedFileURL.path
        guard dstPath != srcPath, !dstPath.hasPrefix(srcPath + "/") else {
            errorMessage = "Can’t move a folder into itself."
            return false
        }
        let dest = destDir.appendingPathComponent(item.url.lastPathComponent)
        guard isWithinRoot(dest) else {
            errorMessage = "Refused: move target is outside the opened folder."
            return false
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            errorMessage = "“\(item.url.lastPathComponent)” already exists in \(destDir.lastPathComponent)."
            return false
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            errorMessage = nil
            load()
            return true
        } catch {
            errorMessage = "Move failed: \(error.localizedDescription)"
            return false
        }
    }
}
