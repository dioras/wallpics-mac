import AppKit
import CoreGraphics

/// Builds the static desktop "poster" shown for an animated/shader wallpaper on the lock/login
/// screen and whenever the app isn't running. The goal is a pixel-faithful freeze-frame: the
/// content is composited at the display's backing resolution (so it's exactly as sharp as the live
/// wallpaper), the watermark is drawn with the **same spec as the live `WatermarkOverlay`** scaled
/// by the display scale (so it doesn't change size between locked/unlocked), and it's written
/// lossless (PNG) so there are no JPEG artifacts.
enum WallpaperPoster {
    /// The badge geometry, in points — shared conceptually with `WatermarkOverlay` so the baked
    /// still and the live overlay look identical. Drawn here at `scale` (pixels per point).
    private enum Badge {
        static let icon: CGFloat = 53
        static let width: CGFloat = 420
        static let height: CGFloat = 83
        static let pad: CGFloat = 13
        static let corner: CGFloat = 14
        static let titleSize: CGFloat = 18
        static let subtitleSize: CGFloat = 11
        static let xFraction: CGFloat = 0.025
        static let yFraction: CGFloat = 0.07
    }

    /// Compose `content` (a shader render or a video frame) into a `targetSize`-pixel image,
    /// aspect-fill cropped like the live wallpaper, watermark it for free users, and write a PNG.
    static func write(content: CGImage, targetSize: CGSize, scale: CGFloat, isPro: Bool, appIcon: NSImage?, to destination: URL) -> Bool {
        let width = max(1, Int(targetSize.width))
        let height = max(1, Int(targetSize.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .high

        // Aspect-fill the content (matches the live video's RESIZE_MODE_ZOOM / a full-screen shader).
        let cw = CGFloat(content.width), ch = CGFloat(content.height)
        let fill = max(targetSize.width / cw, targetSize.height / ch)
        let dw = cw * fill, dh = ch * fill
        ctx.draw(content, in: CGRect(x: (targetSize.width - dw) / 2, y: (targetSize.height - dh) / 2, width: dw, height: dh))

        if !isPro {
            drawWatermark(in: ctx, imageSize: targetSize, scale: scale, appIcon: appIcon)
        }

        guard let out = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        else { return false }
        try? FileManager.default.removeItem(at: destination)
        return (try? png.write(to: destination, options: .atomic)) != nil
    }

    private static func drawWatermark(in ctx: CGContext, imageSize: CGSize, scale: CGFloat, appIcon: NSImage?) {
        let icon = Badge.icon * scale
        let width = Badge.width * scale
        let height = Badge.height * scale
        let pad = Badge.pad * scale
        let x = max(imageSize.width * Badge.xFraction, 28 * scale)
        let y = max(imageSize.height * Badge.yFraction, 28 * scale)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let pill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                                xRadius: Badge.corner * scale, yRadius: Badge.corner * scale)
        NSColor.black.withAlphaComponent(0.5).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        pill.lineWidth = max(1, scale)
        pill.stroke()

        if let appIcon {
            appIcon.draw(in: NSRect(x: x + pad, y: y + (height - icon) / 2, width: icon, height: icon),
                         from: .zero, operation: .sourceOver, fraction: 0.85)
        }

        let textX = x + pad + icon + 11 * scale
        let title = NSAttributedString(string: "WallPics", attributes: [
            .font: NSFont.systemFont(ofSize: Badge.titleSize * scale, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.98)
        ])
        let subtitle = NSAttributedString(string: String(localized: "Unlock Pro to remove this watermark"), attributes: [
            .font: NSFont.systemFont(ofSize: Badge.subtitleSize * scale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ])
        let ts = title.size(), ss = subtitle.size()
        let blockH = ts.height + ss.height + 2 * scale
        let blockBottom = y + (height - blockH) / 2
        subtitle.draw(at: CGPoint(x: textX, y: blockBottom))
        title.draw(at: CGPoint(x: textX, y: blockBottom + ss.height + 2 * scale))

        NSGraphicsContext.restoreGraphicsState()
    }
}
