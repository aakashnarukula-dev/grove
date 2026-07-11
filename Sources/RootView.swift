import SwiftUI

/// The four ways to view an opened folder. Shared across the graph toolbar and the
/// Finder header so a single switcher moves between all of them.
enum AppView: String, CaseIterable { case graph, grid, list, column }

/// Top-level router. With no folder open it shows the welcome screen; otherwise it
/// shows the node graph or the Finder-style browser depending on `appView`.
/// `.id(root)` gives each opened folder fresh view state (stores, expansion,
/// navigation) so switching folders starts clean.
struct RootView: View {
    @EnvironmentObject var library: Library
    @State private var appView: AppView = .graph

    var body: some View {
        if let root = library.root {
            Group {
                if appView == .graph {
                    GraphView(root: root, appView: $appView)
                } else {
                    ContentView(root: root, appView: $appView)
                }
            }
            .id(root.path)
        } else {
            WelcomeView()
        }
    }
}

/// Unified 4-way view switcher (graph / grid / list / column). Used in both the
/// dark graph toolbar (`dark: true`) and the light Finder header (`dark: false`).
struct ViewSwitcher: View {
    @Binding var appView: AppView
    var dark: Bool

    private static let items: [(view: AppView, icon: String, help: String)] = [
        (.graph,  "point.3.connected.trianglepath.dotted", "Graph"),
        (.grid,   "square.grid.2x2",                        "Grid"),
        (.list,   "list.bullet",                            "List"),
        (.column, "rectangle.split.3x1",                    "Columns"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items, id: \.view) { item in
                let selected = appView == item.view
                Button { appView = item.view } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? selectedFill : Color.clear))
                        .foregroundColor(foreground(selected))
                        // Make the whole box tappable, not just the glyph pixels.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(trackFill))
    }

    private var selectedFill: Color { dark ? Color.white.opacity(0.22) : Color.accentColor }
    private var trackFill: Color { dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.06) }
    private func foreground(_ selected: Bool) -> Color {
        dark ? .white.opacity(selected ? 1 : 0.7) : (selected ? .white : .primary)
    }
}
