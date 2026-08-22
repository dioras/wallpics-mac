import AppKit
import Foundation

enum PetBackdropRenderer {
    private static let paper = NSColor(calibratedRed: 0.965, green: 0.961, blue: 0.949, alpha: 1)
    private static let ink = NSColor(calibratedWhite: 0.09, alpha: 1)
    private static let muted = NSColor(calibratedWhite: 0.42, alpha: 1)
    private static let hairline = NSColor(calibratedWhite: 0.80, alpha: 1)

    static func image(size: CGSize,
                      species: PetSpecies,
                      profile: PetProfile,
                      guardian: String,
                      petFrame: CGRect?) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        paper.setFill()
        NSRect(origin: .zero, size: size).fill()

        let unit = min(size.height, size.width * 9 / 16)
        let margin = unit * 0.12
        let gutter = unit * 0.06

        let occupied = petFrame ?? .zero
        let leftFree = max(0, occupied.minX - gutter - margin)
        let rightFree = max(0, size.width - margin - (occupied.maxX + gutter))
        let preferLeft = occupied.isEmpty || leftFree >= rightFree
        let available = occupied.isEmpty ? size.width - margin * 2
                                         : max(leftFree, rightFree)
        let columnWidth = max(unit * 0.30, min(min(size.width * 0.40, unit * 0.80), available))
        let originX = preferLeft ? margin : size.width - margin - columnWidth

        let titleSize = unit * 0.085
        let bodySize = unit * 0.0235
        var top = size.height - margin

        let title = profile.displayName.isEmpty ? species.name : profile.displayName
        top -= drawBlock(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
            .foregroundColor: ink
        ]), x: originX, top: top, width: columnWidth)

        top -= bodySize * 2.2

        let rows: [(String, String)] = [
            (String(localized: "Name:"), profile.displayName.isEmpty ? species.name : profile.displayName),
            (String(localized: "Breed:"), profile.breed),
            (String(localized: "Gender:"), profile.gender),
            (String(localized: "Likes:"), profile.likes),
            (String(localized: "Dislikes:"), profile.dislikes),
            (String(localized: "Guardian:"), guardian)
        ].filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }

        let tab = columnWidth * 0.30
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: tab, options: [:])]
        style.defaultTabInterval = tab
        style.headIndent = tab
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = bodySize * 0.62

        let details = NSMutableAttributedString()
        for (label, value) in rows {
            details.append(NSAttributedString(string: label + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold),
                .foregroundColor: ink, .paragraphStyle: style
            ]))
            details.append(NSAttributedString(string: value + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular),
                .foregroundColor: muted, .paragraphStyle: style
            ]))
        }
        top -= drawBlock(details, x: originX, top: top, width: columnWidth)

        let notes = profile.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return image }

        top -= bodySize * 1.8
        hairline.setFill()
        NSRect(x: originX, y: top, width: columnWidth, height: max(1, unit * 0.0012)).fill()
        top -= bodySize * 1.7

        top -= drawBlock(NSAttributedString(string: String(localized: "Pet Notes"), attributes: [
            .font: NSFont.systemFont(ofSize: bodySize * 1.1, weight: .bold),
            .foregroundColor: ink
        ]), x: originX, top: top, width: columnWidth)

        top -= bodySize * 0.9

        let noteStyle = NSMutableParagraphStyle()
        noteStyle.lineBreakMode = .byWordWrapping
        noteStyle.lineSpacing = bodySize * 0.42
        _ = drawBlock(NSAttributedString(string: notes, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular),
            .foregroundColor: muted, .paragraphStyle: noteStyle
        ]), x: originX, top: top, width: columnWidth)

        return image
    }

    @discardableResult
    private static func drawBlock(_ text: NSAttributedString, x: CGFloat,
                                  top: CGFloat, width: CGFloat) -> CGFloat {
        let bounds = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin])
        let height = ceil(bounds.height)
        text.draw(with: CGRect(x: x, y: top - height, width: width, height: height),
                  options: [.usesLineFragmentOrigin])
        return height
    }

    static func writePNG(_ image: NSImage, to url: URL, pixelSize: CGSize) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(pixelSize.width),
                                         pixelsHigh: Int(pixelSize.height),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw PetBackdropError.allocationFailed
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw PetBackdropError.encodeFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

enum PetBackdropError: LocalizedError {
    case allocationFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .allocationFailed: return "Could not allocate the backdrop bitmap"
        case .encodeFailed: return "Could not encode the backdrop image"
        }
    }
}
