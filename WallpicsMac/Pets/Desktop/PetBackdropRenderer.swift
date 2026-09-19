import AppKit
import Foundation

enum PetBackdropRenderer {
    private static let paper = NSColor(calibratedRed: 0.965, green: 0.961, blue: 0.949, alpha: 1)
    private static let ink = NSColor(calibratedWhite: 0.09, alpha: 1)
    private static let muted = NSColor(calibratedWhite: 0.42, alpha: 1)
    private static let hairline = NSColor(calibratedWhite: 0.80, alpha: 1)

    private static let minimumScale: CGFloat = 0.6
    private static let scaleStep: CGFloat = 0.05

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

        let title = profile.displayName.isEmpty ? species.name : profile.displayName
        let rows: [(String, String)] = [
            (String(localized: "Name:"), profile.displayName.isEmpty ? species.name : profile.displayName),
            (String(localized: "Breed:"), profile.breed),
            (String(localized: "Gender:"), profile.gender),
            (String(localized: "Likes:"), profile.likes),
            (String(localized: "Dislikes:"), profile.dislikes),
            (String(localized: "Guardian:"), guardian)
        ].filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }

        let layout = Layout(unit: unit, margin: margin, columnWidth: columnWidth,
                            originX: originX, screenHeight: size.height,
                            title: title, rows: rows)
        let notes = profile.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let floor = margin * 0.5

        var scale: CGFloat = 1
        var headerBottom = layout.header(scale: scale, draw: false)
        while scale > minimumScale,
              layout.notes(notes, from: headerBottom, scale: scale, draw: false) < floor {
            scale -= scaleStep
            headerBottom = layout.header(scale: scale, draw: false)
        }

        let text = fitted(notes, layout: layout, headerBottom: headerBottom,
                          scale: scale, floor: floor)
        layout.header(scale: scale, draw: true)
        layout.notes(text, from: headerBottom, scale: scale, draw: true)

        return image
    }

    private static func fitted(_ notes: String, layout: Layout, headerBottom: CGFloat,
                               scale: CGFloat, floor: CGFloat) -> String {
        guard !notes.isEmpty,
              layout.notes(notes, from: headerBottom, scale: scale, draw: false) < floor
        else { return notes }

        let characters = Array(notes)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = ellipsized(characters, count: mid)
            if layout.notes(candidate, from: headerBottom, scale: scale, draw: false) >= floor {
                low = mid
            } else {
                high = mid - 1
            }
        }
        guard low > 0 else { return "" }
        return ellipsized(characters, count: low)
    }

    private static func ellipsized(_ characters: [Character], count: Int) -> String {
        let head = String(characters[0..<count]).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? "" : head + "…"
    }

    private struct Layout {
        let unit: CGFloat
        let margin: CGFloat
        let columnWidth: CGFloat
        let originX: CGFloat
        let screenHeight: CGFloat
        let title: String
        let rows: [(String, String)]

        @discardableResult
        func header(scale: CGFloat, draw: Bool) -> CGFloat {
            let titleSize = unit * 0.085 * scale
            let bodySize = unit * 0.0235 * scale
            var top = screenHeight - margin

            top -= block(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
                .foregroundColor: PetBackdropRenderer.ink
            ]), top: top, draw: draw)

            top -= bodySize * 2.2

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
                    .foregroundColor: PetBackdropRenderer.ink, .paragraphStyle: style
                ]))
                details.append(NSAttributedString(string: value + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular),
                    .foregroundColor: PetBackdropRenderer.muted, .paragraphStyle: style
                ]))
            }
            top -= block(details, top: top, draw: draw)

            return top
        }

        @discardableResult
        func notes(_ notes: String, from headerBottom: CGFloat,
                   scale: CGFloat, draw: Bool) -> CGFloat {
            guard !notes.isEmpty else { return headerBottom }

            let bodySize = unit * 0.0235 * scale
            var top = headerBottom

            top -= bodySize * 1.8
            if draw {
                PetBackdropRenderer.hairline.setFill()
                NSRect(x: originX, y: top, width: columnWidth,
                       height: max(1, unit * 0.0012)).fill()
            }
            top -= bodySize * 1.7

            top -= block(NSAttributedString(string: String(localized: "Pet Notes"), attributes: [
                .font: NSFont.systemFont(ofSize: bodySize * 1.1, weight: .bold),
                .foregroundColor: PetBackdropRenderer.ink
            ]), top: top, draw: draw)

            top -= bodySize * 0.9

            let noteStyle = NSMutableParagraphStyle()
            noteStyle.lineBreakMode = .byWordWrapping
            noteStyle.lineSpacing = bodySize * 0.42
            top -= block(NSAttributedString(string: notes, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular),
                .foregroundColor: PetBackdropRenderer.muted, .paragraphStyle: noteStyle
            ]), top: top, draw: draw)

            return top
        }

        private func block(_ text: NSAttributedString, top: CGFloat, draw: Bool) -> CGFloat {
            let bounds = text.boundingRect(with: CGSize(width: columnWidth,
                                                        height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin])
            let height = ceil(bounds.height)
            if draw {
                text.draw(with: CGRect(x: originX, y: top - height,
                                       width: columnWidth, height: height),
                          options: [.usesLineFragmentOrigin])
            }
            return height
        }
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
