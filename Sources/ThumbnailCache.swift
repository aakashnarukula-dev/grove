import SwiftUI
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads downsampled image thumbnails OFF the main thread and caches them by
/// "<path>:<mtime>". Never decodes a full-resolution bitmap for a thumbnail —
/// uses ImageIO's CGImageSourceCreateThumbnailAtIndex so a 40MP photo costs the
/// same as a tiny one. The lightbox uses `loadFull` for the full-quality image.
///
/// Everything is keyed on (path, modification time) so a file changing on disk
/// invalidates automatically without a manual purge.
/// `@unchecked Sendable`: `NSCache` is thread-safe, the `queue` is immutable, and
/// `inFlight` is only ever mutated on the main thread (the public entry points and
/// every completion hop back to `DispatchQueue.main`). Safe to pass into the
/// background decode closures.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    /// Edge of the square the thumbnail is downsampled to (point size; we render
    /// ~120pt tiles, so 256px stays crisp on Retina and cheap to decode/scale).
    static let thumbMaxPixel: CGFloat = 256

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 1200            // generous; tiles are tiny (~256px)
        return c
    }()

    /// Off-main serial-ish pool. A concurrent queue keeps the UI responsive while
    /// a burst of newly-visible tiles decode; ImageIO calls are independent.
    private let queue = DispatchQueue(label: "com.grove.thumbnails",
                                      qos: .userInitiated, attributes: .concurrent)

    /// In-flight guard so panning back and forth over a tile doesn't enqueue the
    /// same decode twice. Touched only on the main thread.
    private var inFlight: Set<String> = []

    // MARK: - Cache key

    private func key(for url: URL) -> NSString {
        let path = url.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)??
            .timeIntervalSince1970 ?? 0
        return "\(path):\(mtime)" as NSString
    }

    /// Synchronous cache peek (cheap, main-thread safe). Returns nil if not loaded.
    func cached(_ url: URL) -> NSImage? { cache.object(forKey: key(for: url)) }

    // MARK: - Async thumbnail

    /// Returns the cached thumbnail immediately if present; otherwise kicks off a
    /// background downsample and calls `completion` on the main thread when ready.
    /// Safe to call repeatedly from view bodies — duplicate loads are coalesced.
    @MainActor
    func thumbnail(for url: URL, completion: @escaping (NSImage) -> Void) {
        let k = key(for: url)
        if let hit = cache.object(forKey: k) { completion(hit); return }
        let token = k as String
        if inFlight.contains(token) { return }   // already loading; its completion will publish
        inFlight.insert(token)

        let target = url
        queue.async { [weak self] in
            let image = Self.makeThumbnail(url: target, maxPixel: Self.thumbMaxPixel)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(token)
                guard let image else { return }
                self.cache.setObject(image, forKey: token as NSString)
                completion(image)
            }
        }
    }

    /// Full-resolution decode for the lightbox (still off the main thread).
    func loadFull(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            let img = NSImage(contentsOf: url)
            DispatchQueue.main.async { completion(img) }
        }
    }

    // MARK: - ImageIO downsample

    /// Downsample with ImageIO. kCGImageSourceCreateThumbnailFromImageAlways forces
    /// it to ignore any embedded (possibly huge / wrong-orientation) thumbnail and
    /// scale the full image down to maxPixel; ShouldCacheImmediately decodes now so
    /// scrolling doesn't decode lazily on the main thread later.
    static func makeThumbnail(url: URL, maxPixel: CGFloat) -> NSImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // respect EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
