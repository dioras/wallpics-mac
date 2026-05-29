import AppKit

enum WatermarkService {
    // Proportional sizing keeps the badge consistent across every resolution.
    private static let marginRatio: CGFloat = 0.022
    private static let iconRatio: CGFloat = 0.052   // app-icon size relative to the short side
    private static let iconAlpha: CGFloat = 0.5

    /// Composite a tasteful bottom-left watermark badge (app icon + short "go Pro" message)
    /// for free users. Pro just copies the clean image through. `appIcon` is passed in by the
    /// caller (it must be read on the main thread). `screenAspects` are the width/height ratios
    /// of the user's displays — the badge is placed inside the area that survives macOS's
    /// fill-crop on every one of them, so it's never clipped off-screen.
    static func applyIfNeeded(to sourceURL: URL, destinationURL: URL, isPro: Bool, appIcon: NSImage?, screenAspects: [CGFloat] = []) throws {
        if isPro {
            if sourceURL != destinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
            return
        }

        guard let image = NSImage(contentsOf: sourceURL), let cg = cgImage(from: image) else {
            throw NSError(domain: "WatermarkService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read source image."])
        }

        let width = cg.width
        let height = cg.height
        let minSide = CGFloat(min(width, height))
        let margin = minSide * marginRatio
        let iconSize = max(44, minSide * iconRatio)
        let gap = iconSize * 0.32

        // Region of the image guaranteed visible after macOS center-crops it to fill the
        // screens. The badge's bottom-left anchor lives inside this safe rect.
        let safe = safeVisibleRect(width: CGFloat(width), height: CGFloat(height), aspects: screenAspects)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "WatermarkService", code: 2)
        }

        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        // Two-line text block: brand + a soft upgrade nudge.
        let titleFont = NSFont.systemFont(ofSize: iconSize * 0.40, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: iconSize * 0.30, weight: .medium)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = iconSize * 0.18
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let title = NSAttributedString(string: "WallPics", attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .shadow: shadow
        ])
        let subtitle = NSAttributedString(string: String(localized: "Unlock Pro to remove this watermark"), attributes: [
            .font: subFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
            .shadow: shadow
        ])

        let titleSize = title.size()
        let subSize = subtitle.size()
        let textHeight = titleSize.height + subSize.height + iconSize * 0.04

        // Anchor the badge to the bottom-left of the safe (always-visible) rect.
        let originX = safe.minX + margin
        let originY = safe.minY + margin
        let textX = originX + iconSize + gap

        // Vertically center the text block against the icon (origin is bottom-left).
        let blockBottom = originY + max(0, (iconSize - textHeight) / 2)
        subtitle.draw(at: CGPoint(x: textX, y: blockBottom))
        title.draw(at: CGPoint(x: textX, y: blockBottom + subSize.height + iconSize * 0.04))

        // App icon at reduced alpha.
        if let appIcon {
            let iconRect = NSRect(x: originX, y: originY, width: iconSize, height: iconSize)
            appIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: iconAlpha)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else {
            throw NSError(domain: "WatermarkService", code: 3)
        }

        let bitmap = NSBitmapImageRep(cgImage: output)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw NSError(domain: "WatermarkService", code: 4)
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try jpeg.write(to: destinationURL, options: .atomic)
    }

    /// The sub-rect of the image (bottom-left origin) that remains visible after macOS
    /// center-crops it to fill each display. Intersecting across all displays guarantees the
    /// badge is on-screen everywhere. Falls back to a 21:9-safe inset when no aspects are known.
    private static func safeVisibleRect(width: CGFloat, height: CGFloat, aspects: [CGFloat]) -> CGRect {
        let imageAspect = width / height
        // If we don't know the screens, assume a very wide one (21:9) so we stay safe.
        let effective = aspects.isEmpty ? [21.0 / 9.0] : aspects.filter { $0 > 0 }
        var minX: CGFloat = 0, maxX = width, minY: CGFloat = 0, maxY = height
        for a in effective {
            if imageAspect > a {
                // Image wider than screen -> cropped left/right. Visible width fraction = a/imageAspect.
                let visibleW = width * (a / imageAspect)
                minX = max(minX, (width - visibleW) / 2)
                maxX = min(maxX, (width + visibleW) / 2)
            } else if imageAspect < a {
                // Image taller than screen -> cropped top/bottom.
                let visibleH = height * (imageAspect / a)
                minY = max(minY, (height - visibleH) / 2)
                maxY = min(maxY, (height + visibleH) / 2)
            }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Robust CGImage extraction — NSImage's first representation isn't always a usable
    /// bitmap rep, so fall back to rasterizing the image.
    private static func cgImage(from image: NSImage) -> CGImage? {
        if let rep = image.representations.first as? NSBitmapImageRep, let cg = rep.cgImage {
            return cg
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
