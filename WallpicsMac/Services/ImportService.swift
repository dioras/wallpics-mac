import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Re-adds the "upload your own wallpaper" feature. Supports every format the original app
/// allowed (images, video, GIF, Metal shaders, Rive). The file is copied into the sandbox,
/// a thumbnail is generated, and a local `Wallpaper` is persisted so it shows under Browse →
/// Your Uploads and survives relaunch. Watermarking happens at set-time (mandatory for free).
@MainActor
enum ImportService {
    /// All formats accepted, matching the previously-shipped version.
    static let allowedExtensions: [String] = [
    "png", "jpg", "jpeg", "heic", "heif", "bmp", "tiff", "gif",   // images / gif
        "mp4", "mov", "m4v", "avi", "mkv", "webm",                    // video
        "msl", "metal",                                               // shaders
        "riv"                                                         // rive animations
    ]

    /// Present the open panel and import the chosen file. Returns the persisted local wallpaper.
    static func pickAndImport() async -> Wallpaper? {
        guard let src = pickFile() else { return nil }
        return await importFile(src)
    }

    // MARK: - Picker

    private static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose an image, video, GIF, shader, or Rive file.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Import

    private static func importFile(_ src: URL) async -> Wallpaper? {
        let ext = src.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }

        let id = -abs(Int.random(in: 1...Int.max))
        let importsFolder = await CacheManager.shared.importsFolder
        let assetURL = importsFolder.appendingPathComponent("\(id).\(ext)")
        let thumbURL = importsFolder.appendingPathComponent("\(id)_thumb.jpg")

        // Heavy file I/O / decoding off the main actor.
        let result: Wallpaper? = await Task.detached(priority: .userInitiated) {
            // Under the sandbox, the open-panel URL needs an explicit security-scoped access
            // window around the read/copy.
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            do {
                try? FileManager.default.removeItem(at: assetURL)
                try FileManager.default.copyItem(at: src, to: assetURL)
            } catch {
                Log.ui.error("Import copy failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }

            let (thumbData, size) = await makeThumbnail(for: assetURL, ext: ext)
            var resolvedThumb: URL? = nil
            if let thumbData {
                try? thumbData.write(to: thumbURL, options: .atomic)
                resolvedThumb = thumbURL
            }

            let name = src.deletingPathExtension().lastPathComponent
            return Wallpaper.local(
                id: id,
                name: name.isEmpty ? "Imported" : name,
                fileURL: assetURL,
                thumbnailURL: resolvedThumb,
                width: Int(size.width),
                height: Int(size.height)
            )
        }.value

        if let wp = result {
            await CacheManager.shared.saveImport(wp)
        }
        return result
    }

    // MARK: - Thumbnail + dimensions

    /// Returns a downscaled JPEG thumbnail (nil for formats we can't rasterize cheaply, e.g.
    /// shaders/Rive) and the source pixel size (zero when unknown).
    nonisolated private static func makeThumbnail(for url: URL, ext: String) async -> (Data?, CGSize) {
        let maxDim: CGFloat = 1280
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "bmp", "tiff", "gif":
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, .zero) }
            let size = pixelSize(from: imageSource)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary) else { return (nil, size) }
            return (jpeg(from: cg), size)

        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxDim, height: maxDim)
            var size = CGSize.zero
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let t = natural.applying(transform)
                size = CGSize(width: abs(t.width), height: abs(t.height))
            }
            if let cg = try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image {
                return (jpeg(from: cg), size)
            }
            return (nil, size)

        default: // msl, metal, riv — no cheap offline render; the card uses a tinted placeholder.
            return (nil, .zero)
        }
    }

    nonisolated private static func pixelSize(from source: CGImageSource) -> CGSize {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .zero }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return CGSize(width: w, height: h)
    }

    nonisolated private static func jpeg(from cg: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
