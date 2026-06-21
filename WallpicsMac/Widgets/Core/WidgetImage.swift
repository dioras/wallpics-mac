import AppKit
import ImageIO
import UniformTypeIdentifiers

/// NSImage loading + downsampling for widget rendering, ported from the iOS
/// `WidgetImageDownsampler` (ImageIO is cross-platform; only the result type differs).
///
/// Widgets re-render often (especially interactive ones during a slide animation), so we keep a
/// process-wide cache of decoded, right-sized bitmaps. Without it each re-render re-decodes the
/// PNG/JPEG from disk and the image can flash while SwiftUI swaps bitmaps mid-frame — the same
/// problem the iOS `*AssetsCache` types solve.
enum WidgetImage {
    private static let cache = NSCache<NSString, NSImage>()

    /// Decode + downsample an image file to at most `maxPixelSize` on its long edge.
    static func load(at path: String, maxPixelSize: Int = 512) -> NSImage? {
        let key = "\(path)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = downsample(url: URL(fileURLWithPath: path), maxPixelSize: maxPixelSize) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    static func load(at url: URL, maxPixelSize: Int = 512) -> NSImage? {
        load(at: url.path, maxPixelSize: maxPixelSize)
    }

    private static func downsample(url: URL, maxPixelSize: Int) -> NSImage? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Clear cached entries for a path prefix (used when an instance's photos change).
    static func invalidate(pathPrefix: String) {
        // NSCache has no enumeration; the cheapest correct thing is a full clear. Widget edits are
        // rare and the cache refills lazily, so this is fine.
        _ = pathPrefix
        cache.removeAllObjects()
    }
}

extension NSImage {
    /// JPEG-encode at the given quality, for persisting imported/baked photos.
    func jpegData(compressionQuality: CGFloat = 0.9) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    /// PNG-encode (preserves alpha), for static images and transparent assets.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
