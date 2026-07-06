import SwiftUI

/// Top-level router. With no folder open it shows the welcome screen; otherwise
/// it switches between the ComfyUI-style node graph (default) and the classic
/// Finder-style browser. `.id(root)` gives each opened folder fresh view state
/// (stores, expansion, navigation) so switching folders starts clean.
struct RootView: View {
    @EnvironmentObject var library: Library
    @State private var useGraph = true

    var body: some View {
        if let root = library.root {
            Group {
                if useGraph {
                    GraphView(root: root, useGraph: $useGraph)
                } else {
                    ContentView(root: root, useGraph: $useGraph)
                }
            }
            .id(root.path)
        } else {
            WelcomeView()
        }
    }
}
