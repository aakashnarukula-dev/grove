import SwiftUI
import AppKit

/// What the lightbox is showing: the currently-selected image plus every image
/// in the SAME folder (for the filmstrip). Identity = the current image path so
/// the overlay re-presents cleanly when the user opens a different tile.
struct LightboxItem: Identifiable, Equatable {
    let images: [URL]      // all images in the folder, display order
    var current: URL       // the one shown in the main pane
    var id: String { current.path }

    static func == (a: LightboxItem, b: LightboxItem) -> Bool {
        a.current == b.current && a.images == b.images
    }
}

/// Full-screen overlay (a ZStack layer above the graph). Shows the selected image
/// at full quality — the cached thumbnail scaled up first, swapped for the full
/// decode when it arrives — over a dimmed, click-to-dismiss backdrop, with a
/// horizontally-scrollable filmstrip of the folder's images at the bottom.
struct LightboxView: View {
    @State var item: LightboxItem
    let onClose: () -> Void

    @State private var fullImage: NSImage?
    @State private var thumbImage: NSImage?

    var body: some View {
        ZStack {
            // Dimmed backdrop — clicking it dismisses.
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                mainPane
                filmstrip
            }

            // Prev / next arrows, vertically centred — only when there's >1 image.
            if item.images.count > 1 {
                HStack {
                    navArrow("chevron.left") { step(-1) }
                    Spacer()
                    navArrow("chevron.right") { step(1) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 108)   // sit above the filmstrip
            }

            // Close button, top-right.
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .padding(18)
                    .keyboardShortcut(.cancelAction)   // Esc dismisses
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the window
        .onAppear { load() }
        .onChange(of: item.current) { _ in load() }
        // Esc dismisses; ← / → step through the folder's images.
        .background(KeyCatcher(onEsc: onClose, onLeft: { step(-1) }, onRight: { step(1) }))
    }

    private func navArrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    /// Move to the previous/next image in the folder (wraps around).
    private func step(_ delta: Int) {
        let imgs = item.images
        guard imgs.count > 1, let idx = imgs.firstIndex(of: item.current) else { return }
        item.current = imgs[(idx + delta + imgs.count) % imgs.count]
    }

    // MARK: - Main image pane

    private var mainPane: some View {
        GeometryReader { geo in
            ZStack {
                if let img = fullImage ?? thumbImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        // Blur the thumbnail a touch while the full image loads so the
                        // upscale doesn't look harsh.
                        .blur(radius: fullImage == nil ? 1.5 : 0)
                } else {
                    ProgressView().scaleEffect(1.4).tint(.white)
                }
                if fullImage == nil && thumbImage != nil {
                    VStack { Spacer(); HStack { Spacer()
                        ProgressView().tint(.white).padding(10)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                            .padding(14) } }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(item.images, id: \.path) { url in
                        FilmstripThumb(url: url, isCurrent: url == item.current)
                            .id(url.path)
                            .onTapGesture { item.current = url }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(Color.black.opacity(0.35))
            .onAppear { proxy.scrollTo(item.current.path, anchor: .center) }
            .onChange(of: item.current) { cur in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(cur.path, anchor: .center) }
            }
        }
        .frame(height: 108)
    }

    // MARK: - Loading

    private func load() {
        // Reuse the cached thumbnail as an instant low-res preview; load full async.
        thumbImage = ThumbnailCache.shared.cached(item.current)
        fullImage = nil
        let target = item.current
        ThumbnailCache.shared.loadFull(target) { img in
            // Ignore a stale completion if the user already switched images.
            if target == item.current { fullImage = img }
        }
    }
}

/// One filmstrip cell — reuses the shared thumbnail cache (never re-decodes).
private struct FilmstripThumb: View {
    let url: URL
    let isCurrent: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2))
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isCurrent ? Color.white : Color.white.opacity(0.18),
                    lineWidth: isCurrent ? 3 : 1))
        .scaleEffect(isCurrent ? 1.0 : 0.94)
        .onAppear {
            if image == nil {
                ThumbnailCache.shared.thumbnail(for: url) { image = $0 }
            }
        }
    }
}

/// Tiny NSView shim for keyboard control of the lightbox: Esc dismisses, ←/→ step
/// through images. (keyboardShortcut needs a focused responder; this is a reliable
/// fallback that grabs first responder and listens for the raw keyCodes.)
private struct KeyCatcher: NSViewRepresentable {
    let onEsc: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.onEsc = onEsc; v.onLeft = onLeft; v.onRight = onRight
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? KeyView else { return }
        v.onEsc = onEsc; v.onLeft = onLeft; v.onRight = onRight
    }
    final class KeyView: NSView {
        var onEsc: (() -> Void)?
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53:  onEsc?()      // Esc
            case 123: onLeft?()     // ←
            case 124: onRight?()    // →
            default:  super.keyDown(with: event)
            }
        }
    }
}
