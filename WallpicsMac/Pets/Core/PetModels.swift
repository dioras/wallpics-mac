import CoreGraphics
import Foundation

struct PetSpecies: Identifiable, Hashable, Sendable {
    let slug: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let poseCount: Int
    let neutralPose: Int
    let faceCenter: CGPoint
    let subjectHeight: CGFloat
    let subjectBottom: CGFloat
    let angleTable: [Int]
    let mirrorTable: [Bool]
    let pivotUp: Int
    let pivotDown: Int
    let mediaURL: URL
    let posterURL: URL

    var id: String { slug }
    var aspectRatio: CGFloat {
        pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1
    }
}

enum PetSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    var pointHeight: CGFloat {
        switch self {
        case .small: return 190
        case .medium: return 280
        case .large: return 380
        }
    }

    var label: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

enum PetAnchor: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottomLeading, bottomCenter, bottomTrailing, leading, trailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomLeading: return String(localized: "Bottom Left")
        case .bottomCenter: return String(localized: "Bottom Center")
        case .bottomTrailing: return String(localized: "Bottom Right")
        case .leading: return String(localized: "Left Edge")
        case .trailing: return String(localized: "Right Edge")
        }
    }

    var symbol: String {
        switch self {
        case .bottomLeading: return "arrow.down.left"
        case .bottomCenter: return "arrow.down"
        case .bottomTrailing: return "arrow.down.right"
        case .leading: return "arrow.left"
        case .trailing: return "arrow.right"
        }
    }

    func rect(for size: CGSize, in bounds: CGRect, margin: CGFloat) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch self {
        case .bottomLeading:
            x = bounds.minX + margin
            y = bounds.minY
        case .bottomCenter:
            x = bounds.midX - size.width / 2
            y = bounds.minY
        case .bottomTrailing:
            x = bounds.maxX - size.width - margin
            y = bounds.minY
        case .leading:
            x = bounds.minX + margin
            y = bounds.midY - size.height / 2
        case .trailing:
            x = bounds.maxX - size.width - margin
            y = bounds.midY - size.height / 2
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

struct PetPlacement: Codable, Equatable, Sendable {
    var speciesSlug: String
    var size: PetSize = .medium
    var anchor: PetAnchor = .bottomTrailing
    var allScreens: Bool = true
}

struct PetsState: Codable, Sendable {
    var version: Int = 1
    var placement: PetPlacement?
}
