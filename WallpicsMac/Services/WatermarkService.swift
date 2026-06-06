import AppKit

enum WatermarkService {
    /// Composite a large, dock-clearing watermark badge (app icon + "go Pro" message)
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
        // Visible but compact badge (~6% of the short side) — sits low, just above the Dock.
        let iconSize = max(56, minSide * 0.06)
        let gap = iconSize * 0.30
        let innerPad = iconSize * 0.30

        // Region of the image guaranteed visible after macOS center-crops it to fill the screens.
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

        // Two-line text block: brand + an upgrade nudge.
        let titleFont = NSFont.systemFont(ofSize: iconSize * 0.44, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: iconSize * 0.34, weight: .medium)
        let title = NSAttributedString(string: "WallPics", attributes: [
            .font: titleFont, .foregroundColor: NSColor.white.withAlphaComponent(0.98)
        ])
        let subtitle = NSAttributedString(string: String(localized: "Unlock Pro to remove this watermark"), attributes: [
            .font: subFont, .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ])

        let titleSize = title.size()
        let subSize = subtitle.size()
        let textWidth = max(titleSize.width, subSize.width)
        let textHeight = titleSize.height + subSize.height + iconSize * 0.05

        // Pill badge: centered horizontally in the safe rect and lifted ~13% off the bottom so it
        // clears the Dock and is genuinely noticeable (the old small bottom-left mark hid behind it).
        let badgeWidth = innerPad + iconSize + gap + textWidth + innerPad
        let badgeHeight = max(iconSize, textHeight) + innerPad * 1.4
        // Left-aligned (with a small inset), low above the bottom.
        let badgeX = safe.minX + max(innerPad, minSide * 0.022)
        let badgeY = safe.minY + safe.height * 0.07

        let pill = NSBezierPath(roundedRect: NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight),
                                xRadius: badgeHeight * 0.30, yRadius: badgeHeight * 0.30)
        NSColor.black.withAlphaComponent(0.5).setFill()
        pill.fill()
        pill.lineWidth = max(1, minSide * 0.001)
        NSColor.white.withAlphaComponent(0.14).setStroke()
        pill.stroke()

        // App icon.
        let iconX = badgeX + innerPad
        let iconY = badgeY + (badgeHeight - iconSize) / 2
        if let appIcon {
            appIcon.draw(in: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize),
                         from: .zero, operation: .sourceOver, fraction: 0.9)
        }

        // Text, vertically centered against the badge.
        let textX = iconX + iconSize + gap
        let blockBottom = badgeY + (badgeHeight - textHeight) / 2
        subtitle.draw(at: CGPoint(x: textX, y: blockBottom))
        title.draw(at: CGPoint(x: textX, y: blockBottom + subSize.height + iconSize * 0.05))

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
