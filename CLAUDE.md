# Grove — project guide

Native macOS app that visualizes any folder as an interactive ComfyUI-style node
graph, with a Finder-style browser alternative. Pure SwiftUI + AppKit, **no
dependencies**, compiled directly with `swiftc`.

## Build / run

```sh
./build.sh           # compile Sources/*.swift → build/Grove.app (ad-hoc signed)
./build.sh --open    # build + launch
./make-icon.sh       # regenerate AppIcon.icns (optional)
open "build/Grove.app"
```

- Targets `<arch>-apple-macosx13.0` (arm64 or x86_64, whichever the Mac is).
- Compiles with `swiftc -O` over all of `Sources/*.swift` into one binary.
- **No test suite, no package manager, no Xcode project.** Verification =
  `./build.sh` compiles clean, then launch and exercise the UI.
- Requires macOS 13+ and the Swift toolchain (Xcode Command Line Tools).

## Cache-bust / verify after a change

`./build.sh` does `rm -rf build/` first, so every build is clean — no stale
artifact risk. To verify a change: run `./build.sh` (must compile with no
errors), then `open "build/Grove.app"` and drive the affected view.

## Architecture (all in `Sources/`)

| File | Role |
|------|------|
| `GroveApp.swift` | `@main` app entry, window, menu commands (Open Folder, Open Recent) |
| `Library.swift` | Opened folder + recents list, persisted in `UserDefaults` |
| `RootView.swift` | Router: welcome ↔ graph view ↔ Finder view |
| `WelcomeView.swift` | First-run screen: open a folder or pick a recent |
| `FolderStore.swift` | Root-scoped filesystem model — read, navigate, rename, move, trash |
| `GraphModel.swift` | Builds the tidy-tree layout (nodes + edges) |
| `GraphView.swift` | Interactive canvas: nodes, edges, thumbnails, drag-and-drop |
| `ContentView.swift` | Finder-style grid / list / column (Miller) browser |
| `Lightbox.swift` | Full-screen image viewer with filmstrip |
| `ImageInfoView.swift` | Image metadata panel |
| `ThumbnailCache.swift` | Off-main ImageIO thumbnail cache keyed on (path, mtime) |

Data flow: `Library` holds the chosen root → `FolderStore` is the scoped FS
model → `GraphModel` derives layout from it → `GraphView`/`ContentView` render.
The folder on disk is the single source of truth; view re-reads every ~2s (live
mirror).

## Hard rules / gotchas

- **Sandbox of intent:** every read/rename/move/delete MUST be path-checked to
  stay inside the opened root. `FolderStore` enforces this — preserve it.
- **Delete = move to Trash** (recoverable via `NSWorkspace.recycle`), never a
  permanent unlink. Do not change this.
- Thumbnail downsampling happens **off the main thread**; keep it that way for
  large photo folders to stay smooth. Off-screen tiles are culled.
- Bundle id `com.grove.app`, version in `build.sh`'s Info.plist heredoc.
- Info.plist declares TCC usage strings (Desktop/Documents/Downloads/removable);
  new protected-location access needs matching `NS*UsageDescription` keys.

## Git / commits (repo-specific)

- Remote: `origin` → github.com/aakashnarukula-dev/grove.
- Author MUST be `aakashnarukula-dev <aakashnarukula.dev@gmail.com>`.
- **Never** add a `Co-Authored-By: Claude`/Anthropic trailer. No "claude" in
  contributors. (Set repo-local `git config user.name/user.email` before first
  commit.)
- Latest release: v1.0, universal binary zip attached to GitHub Releases.
