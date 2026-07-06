import SwiftUI
import AppKit

/// The single source of truth for which folder the app is currently viewing,
/// plus a short list of recently-opened folders. Persisted in UserDefaults so
/// the last folder reopens on the next launch. This is the ONLY place that
/// decides the root; every view/store derives its root from here.
@MainActor
final class Library: ObservableObject {
    /// The folder currently open (nil → show the welcome screen).
    @Published var root: URL?
    /// Recently-opened folders, most-recent first (deduped, capped).
    @Published var recents: [URL] = []

    private let rootKey = "currentFolder"
    private let recentsKey = "recentFolders"
    private let maxRecents = 12

    init() {
        let d = UserDefaults.standard
        recents = (d.array(forKey: recentsKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { Self.isDirectory($0) }
        if let p = d.string(forKey: rootKey), Self.isDirectory(URL(fileURLWithPath: p)) {
            root = URL(fileURLWithPath: p, isDirectory: true)
        }
    }

    /// Open a folder: make it the root and record it in recents.
    func open(_ url: URL) {
        let dir = url.standardizedFileURL
        guard Self.isDirectory(dir) else { return }
        root = dir
        recents = ([dir] + recents.filter { $0 != dir }).prefix(maxRecents).map { $0 }
        persist()
    }

    /// Prompt the user to pick any folder on disk (macOS grants read access to
    /// whatever they choose — the standard, un-sandboxed open-panel flow).
    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to view as a graph"
        if let root { panel.directoryURL = root.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Return to the welcome screen (keeps recents).
    func close() {
        root = nil
        UserDefaults.standard.removeObject(forKey: rootKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(root?.path, forKey: rootKey)
        d.set(recents.map { $0.path }, forKey: recentsKey)
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
