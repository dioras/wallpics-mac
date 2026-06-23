import AppKit
import ImageIO
import UniformTypeIdentifiers

enum WidgetImage {
    private static let cache = NSCache<NSString, NSImage>()

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
}

extension NSImage {
    func jpegData(compressionQuality: CGFloat = 0.9) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
