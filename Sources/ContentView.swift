import SwiftUI
import AppKit

enum ViewMode: String { case grid, list, column }

struct ContentView: View {
    @EnvironmentObject var library: Library
    @StateObject private var store: FolderStore
    @Binding var useGraph: Bool

    init(root: URL, useGraph: Binding<Bool>) {
        _store = StateObject(wrappedValue: FolderStore(root: root))
        _useGraph = useGraph
    }

    @State private var mode: ViewMode = .grid
    @State private var renameTarget: FolderItem?
    @State private var deleteTarget: FolderItem?

    // Live "mirror": re-read the current folder every few seconds, but never
    // while a rename/delete dialog is open (so it can't yank the UI).
    private let tick = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = store.errorMessage { banner(err) }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.load() }
        .onReceive(tick) { _ in
            if mode != .column, renameTarget == nil, deleteTarget == nil { store.load() }
        }
        .sheet(item: $renameTarget) { target in
            RenameSheet(originalName: target.name) { newName in
                store.rename(target, to: newName); renameTarget = nil
            } onCancel: { renameTarget = nil }
        }
        .confirmationDialog(
            "Move “\(deleteTarget?.name ?? "")” to Trash?",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { item in
            Button("Move to Trash", role: .destructive) { store.trash(item); deleteTarget = nil }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("It goes to the Trash (recoverable). Only this item inside the opened folder is affected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            backForward
            if mode == .column {
                Text(store.root.lastPathComponent).font(.headline)
            } else {
                breadcrumb
            }
            Spacer()
            if mode != .column {
                Text(folderCountSummary).font(.callout).foregroundColor(.secondary)
            }
            Button { store.load() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
            Button { library.openPanel() } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Open a different folder (⌘O)")
            Button { useGraph = true } label: {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.plain).help("Switch to node graph")
            Picker("", selection: $mode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "rectangle.split.3x1").tag(ViewMode.column)
            }
            .pickerStyle(.segmented)
            .frame(width: 116)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Finder-style back/forward pair. Always present; each greys out when there's
    /// nowhere to go (so at the root both are disabled). Disabled in column mode.
    private var backForward: some View {
        let backOff = mode == .column || !store.canGoBack
        let fwdOff  = mode == .column || !store.canGoForward
        return HStack(spacing: 0) {
            Button { store.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 20)
            }
            .buttonStyle(.plain).disabled(backOff).help("Back")
            Divider().frame(height: 14)
            Button { store.goForward() } label: {
                Image(systemName: "chevron.right").frame(width: 30, height: 20)
            }
            .buttonStyle(.plain).disabled(fwdOff).help("Forward")
        }
        .font(.system(size: 13, weight: .semibold))
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.10)))
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                let isLast = idx == store.breadcrumbs.count - 1
                Button { store.goToBreadcrumb(crumb.url) } label: {
                    Text(crumb.label)
                        .font(isLast ? .headline : .body)
                        .foregroundColor(isLast ? .primary : .secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(isLast)
            }
        }
    }

    private var folderCountSummary: String {
        let dirs = store.items.filter { $0.isDirectory }.count
        let files = store.items.count - dirs
        var parts: [String] = []
        if dirs > 0 { parts.append("\(dirs) folder\(dirs == 1 ? "" : "s")") }
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if mode == .column {
            ColumnBrowser(store: store, renameTarget: $renameTarget, deleteTarget: $deleteTarget)
        } else if store.items.isEmpty && store.errorMessage == nil {
            VStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 42)).foregroundColor(.secondary)
                Text("Empty").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    ForEach(store.items) { gridCard($0) }
                }
                .padding(20)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.items) { listRow($0) }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func gridCard(_ item: FolderItem) -> some View {
        let selected = store.selection == item.id
        return VStack(spacing: 6) {
            Image(nsImage: Self.icon(item.url)).resizable().interpolation(.high)
                .frame(width: 64, height: 64)
            Text(item.name).font(.system(size: 12)).multilineTextAlignment(.center)
                .lineLimit(2).frame(maxWidth: .infinity)
            Text(countLabel(item)).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(8).frame(height: 132)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.isDirectory { store.open(item) } }
        .onTapGesture { store.selection = item.id }
        .contextMenu { rowMenu(item) }
    }

    private func listRow(_ item: FolderItem) -> some View {
        let selected = store.selection == item.id
        return HStack(spacing: 10) {
            Image(nsImage: Self.icon(item.url)).resizable().interpolation(.high)
                .frame(width: 22, height: 22)
            Text(item.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Text(countLabel(item)).font(.system(size: 11)).foregroundColor(.secondary)
            if item.isDirectory {
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.isDirectory { store.open(item) } }
        .onTapGesture { store.selection = item.id }
        .contextMenu { rowMenu(item) }
    }

    @ViewBuilder private func rowMenu(_ item: FolderItem) -> some View {
        if item.isDirectory { Button("Open") { store.open(item) }; Divider() }
        Button("Rename…") { renameTarget = item }
        Button("Reveal in Finder") { store.revealInFinder(item) }
        Divider()
        Button("Move to Trash") { deleteTarget = item }
    }

    private func countLabel(_ item: FolderItem) -> String {
        guard item.isDirectory else {
            return item.url.pathExtension.isEmpty ? "file" : item.url.pathExtension.uppercased()
        }
        let sub = item.subfolderCount, pics = item.pictureCount
        var parts: [String] = []
        if sub > 0 { parts.append("\(sub) folder\(sub == 1 ? "" : "s")") }
        if pics > 0 { parts.append("\(pics) picture\(pics == 1 ? "" : "s")") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }

    static func icon(_ url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 64, height: 64)
        return img
    }
}

// MARK: - Column (Miller) browser

struct ColumnBrowser: View {
    @ObservedObject var store: FolderStore
    @Binding var renameTarget: FolderItem?
    @Binding var deleteTarget: FolderItem?

    @State private var trail: [URL] = []      // directories shown, trail[0] == root
    @State private var leaf: URL?             // a selected file (no child column)
    @State private var columns: [[FolderItem]] = []

    private let tick = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(trail.enumerated()), id: \.element) { idx, dir in
                        columnView(idx: idx, dir: dir).id(idx)
                        Divider()
                    }
                }
            }
            .onChange(of: trail.count) { _ in
                withAnimation { proxy.scrollTo(max(trail.count - 1, 0), anchor: .trailing) }
            }
        }
        .onAppear { if trail.isEmpty { trail = [store.root] }; reload() }
        .onChange(of: trail) { _ in reload() }
        .onReceive(tick) { _ in if renameTarget == nil, deleteTarget == nil { reload() } }
    }

    private func columnView(idx: Int, dir: URL) -> some View {
        let items = idx < columns.count ? columns[idx] : []
        let activeURL: URL? = {
            if idx + 1 < trail.count { return trail[idx + 1] }
            if let leaf, leaf.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { return leaf }
            return nil
        }()
        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    columnRow(item,
                              active: item.url.standardizedFileURL == activeURL?.standardizedFileURL,
                              idx: idx)
                }
            }
            .padding(6)
        }
        .frame(width: 250)
    }

    private func columnRow(_ item: FolderItem, active: Bool, idx: Int) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: ContentView.icon(item.url)).resizable().interpolation(.high)
                .frame(width: 17, height: 17)
            Text(item.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            if item.isDirectory {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(active ? .white : .secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.accentColor : Color.clear))
        .foregroundColor(active ? .white : .primary)
        .contentShape(Rectangle())
        .onTapGesture { select(item, idx: idx) }
        .contextMenu {
            Button("Rename…") { renameTarget = item }
            Button("Reveal in Finder") { store.revealInFinder(item) }
            Divider()
            Button("Move to Trash") { deleteTarget = item }
        }
    }

    private func select(_ item: FolderItem, idx: Int) {
        if item.isDirectory {
            trail = Array(trail.prefix(idx + 1)) + [item.url]
            leaf = nil
        } else {
            trail = Array(trail.prefix(idx + 1))
            leaf = item.url
        }
    }

    private func reload() {
        // Drop trail entries that vanished (e.g. renamed/trashed); root stays.
        var pruned: [URL] = []
        for (i, dir) in trail.enumerated() {
            if i == 0 || FileManager.default.fileExists(atPath: dir.path) { pruned.append(dir) }
            else { break }
        }
        if pruned.isEmpty { pruned = [store.root] }
        if pruned != trail { trail = pruned }
        columns = trail.map { store.children(of: $0) }
    }
}

// MARK: - Rename sheet

struct RenameSheet: View {
    let originalName: String
    let onRename: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 360)
                .focused($focused).onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { text = originalName; focused = true }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onRename(t)
    }
}
