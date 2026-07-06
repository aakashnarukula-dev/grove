# Grove

**Visualize any folder as an interactive node graph.**

Grove is a small, fast, native macOS app that turns a folder tree into a
ComfyUI-style node graph you can pan, zoom, expand, and reorganize — with a
classic Finder-style browser one click away. Open any folder on your Mac and
explore its structure visually, preview images inline, and tidy things up with
drag-to-move, rename, and move-to-trash.

<!-- Add a screenshot here: docs/screenshot.png -->

## Features

- **Node graph view** — folders become connected cards in a tidy left-to-right
  tree. Each top-level folder gets its own accent color. Pan (drag / two-finger
  swipe), pinch-to-zoom, expand-all / collapse-all.
- **Inline image thumbnails** — a folder of images opens as a compact thumbnail
  grid right in the graph. Off-screen tiles are culled and thumbnails are
  downsampled off the main thread, so even large photo folders stay smooth.
- **Lightbox** — click any thumbnail for a full-quality viewer with a filmstrip;
  arrow keys / on-screen arrows step through the folder, Esc closes.
- **Finder-style browser** — grid, list, and column (Miller) modes, with
  back/forward history and a breadcrumb bar. Toggle between graph and Finder
  views anytime.
- **Reorganize safely** — long-press a folder card and drag it onto another
  folder to move it there. Rename and "Move to Trash" from the right-click menu.
- **Open anything** — pick any folder with ⌘O, drop a folder onto the welcome
  window, or reopen a recent one. Grove remembers the last folder you had open.
- **Live mirror** — the view re-reads the folder every couple of seconds, so
  changes on disk show up on their own.

## Safety

- Every read, rename, move, and delete is **path-checked to be inside the folder
  you opened** — Grove never reaches outside your chosen root.
- **Delete = Move to Trash** (recoverable), never a permanent unlink.
- Grove stores no data of its own beyond your recent-folders list; the folder on
  disk is the single source of truth.

## Requirements

- macOS 13 (Ventura) or later
- Swift toolchain (bundled with the Xcode Command Line Tools: `xcode-select --install`)

## Build & run

```sh
git clone https://github.com/aakashnarukula-dev/grove.git
cd grove
./make-icon.sh          # optional: generate AppIcon.icns (or skip for the default icon)
./build.sh --open       # compile → build/Grove.app → launch
```

Or build then open manually:

```sh
./build.sh
open "build/Grove.app"
```

`build.sh` compiles for your Mac's architecture (Apple Silicon or Intel),
bundles `Grove.app`, and ad-hoc signs it. Drag the built app to `/Applications`
if you want it in your Dock permanently.

On first launch, macOS may ask for permission to read a folder in a protected
location (Desktop, Documents, Downloads, or a removable volume) — click
**Allow**. That's the standard TCC prompt for any app reading those folders.

## How it's built

Pure SwiftUI + AppKit, no dependencies, compiled directly with `swiftc`.

| File | Role |
|------|------|
| `GroveApp.swift` | App entry point, window, and menu commands (Open Folder, Open Recent) |
| `Library.swift` | The opened folder + recents, persisted in `UserDefaults` |
| `RootView.swift` | Router: welcome screen ↔ graph view ↔ Finder view |
| `WelcomeView.swift` | First-run screen: open a folder or pick a recent one |
| `FolderStore.swift` | Root-scoped filesystem model (read, navigate, rename, move, trash) |
| `GraphModel.swift` | Builds the tidy-tree layout of nodes and edges |
| `GraphView.swift` | The interactive canvas: nodes, edges, thumbnails, drag-and-drop |
| `ContentView.swift` | Finder-style grid / list / column browser |
| `Lightbox.swift` | Full-screen image viewer with filmstrip |
| `ThumbnailCache.swift` | Off-main ImageIO thumbnail cache keyed on (path, mtime) |

## License

[MIT](LICENSE) © Aakash Narukula
