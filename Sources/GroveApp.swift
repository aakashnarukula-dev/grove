import SwiftUI
import AppKit

@main
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup("Grove") {
            RootView()
                .environmentObject(library)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 920, height: 600)
        .commands {
            // Replace the (meaningless-here) "New" item with folder commands.
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { library.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(library.recents, id: \.self) { url in
                        Button(url.lastPathComponent) { library.open(url) }
                    }
                    if !library.recents.isEmpty {
                        Divider()
                        Button("Clear Menu") { library.clearRecents() }
                    }
                }
                .disabled(library.recents.isEmpty)

                Divider()

                Button("Close Folder") { library.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(library.root == nil)
            }
        }
    }
}

/// Makes the swiftc-built bundle behave like a normal foreground app
/// (Dock icon, focus on launch) and quit when the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
