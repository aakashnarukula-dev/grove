import SwiftUI
import UniformTypeIdentifiers

/// First-run / no-folder-open screen: open a folder, or pick a recent one.
/// Also accepts a folder dropped onto the window.
struct WelcomeView: View {
    @EnvironmentObject var library: Library
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Grove").font(.system(size: 30, weight: .bold))
                Text("Visualize any folder as an interactive graph.")
                    .font(.title3).foregroundColor(.secondary)
            }

            Button { library.openPanel() } label: {
                Label("Open Folder…", systemImage: "folder")
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)

            if !library.recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8).padding(.bottom, 4)
                    ForEach(library.recents.prefix(6), id: \.self) { url in
                        recentRow(url)
                    }
                }
                .frame(width: 380, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) {
            Text("Tip: drag a folder here, or press ⌘O")
                .font(.caption).foregroundColor(.secondary).padding(.bottom, 16)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, Library.isDirectory(url) else { return }
                DispatchQueue.main.async { library.open(url) }
            }
            return true
        }
    }

    private func recentRow(_ url: URL) -> some View {
        Button { library.open(url) } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 18, height: 18)
                Text(url.lastPathComponent).lineLimit(1)
                Spacer(minLength: 8)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
