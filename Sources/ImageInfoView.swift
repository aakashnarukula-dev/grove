import SwiftUI
import AppKit
import ImageIO

/// Identifiable wrapper so an image URL can drive a `.sheet(item:)`.
struct ImageInfoItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// A compact "Show Info" panel for an image file: preview thumbnail plus name,
/// kind, pixel dimensions, file size, and dates. Everything is read on demand
/// from the file — no state is stored.
struct ImageInfoView: View {
    let url: URL
    let onClose: () -> Void

    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Info").font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15))
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFit().padding(4)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 132, height: 132)

                VStack(alignment: .leading, spacing: 8) {
                    row("Name", url.lastPathComponent)
                    row("Kind", kind)
                    row("Dimensions", dimensions)
                    row("Size", fileSize)
                    row("Created", date(.creationDate))
                    row("Modified", date(.modificationDate))
                }
            }

            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let hit = ThumbnailCache.shared.cached(url) { thumb = hit }
            else { ThumbnailCache.shared.thumbnail(for: url) { thumb = $0 } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption).foregroundColor(.secondary)
                .frame(width: 82, alignment: .trailing)
            Text(value.isEmpty ? "—" : value)
                .font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - File facts

    private var kind: String {
        let ext = url.pathExtension
        return ext.isEmpty ? "File" : "\(ext.uppercased()) image"
    }

    private var attributes: [FileAttributeKey: Any] {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    }

    private var fileSize: String {
        guard let bytes = attributes[.size] as? Int else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func date(_ key: FileAttributeKey) -> String {
        guard let d = attributes[key] as? Date else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    private var dimensions: String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return "" }
        return "\(w) × \(h) px"
    }
}
