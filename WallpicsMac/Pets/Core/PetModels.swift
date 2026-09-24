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
    var wrapsAround: Bool = false
    var gazeLoop: ClosedRange<Int>? = nil
    var isPremium: Bool = false
    var summary: String? = nil
    let mediaURL: URL
    let posterURL: URL

    var id: String { slug }

    var remoteID: Int? { Self.remoteID(fromSlug: slug) }

    private static let remotePrefix = "remote-"

    static func remoteSlug(id: Int) -> String { remotePrefix + String(id) }

    static func remoteID(fromSlug slug: String) -> Int? {
        guard slug.hasPrefix(remotePrefix) else { return nil }
        return Int(slug.dropFirst(remotePrefix.count))
    }

    var gazeSpan: Int {
        guard let lo = angleTable.min(), let hi = angleTable.max() else { return max(poseCount - 1, 1) }
        return max(hi - lo, 1)
    }
    var aspectRatio: CGFloat {
        pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1
    }
}

enum PetSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    var pointHeight: CGFloat {
        switch self {
        case .small: return 300
        case .medium: return 460
        case .large: return 700
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

enum PetSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case calm, normal, alert

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calm: return String(localized: "Calm")
        case .normal: return String(localized: "Normal")
        case .alert: return String(localized: "Alert")
        }
    }

    var detail: String {
        switch self {
        case .calm: return String(localized: "Follows slowly, ignores small moves")
        case .normal: return String(localized: "Balanced tracking")
        case .alert: return String(localized: "Snaps to the cursor straight away")
        }
    }

    var responsePerSecond: Double {
        switch self {
        case .calm: return 5
        case .normal: return 9
        case .alert: return 14
        }
    }

    var turnsPerSecond: Double {
        switch self {
        case .calm: return 0.9
        case .normal: return 1.5
        case .alert: return 2.2
        }
    }

    var deadZoneFraction: CGFloat {
        switch self {
        case .calm: return 0.18
        case .normal: return 0.12
        case .alert: return 0.06
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
    var sensitivity: PetSensitivity = .normal
    var showsProfileBackdrop: Bool = false

    init(speciesSlug: String,
         size: PetSize = .medium,
         anchor: PetAnchor = .bottomTrailing,
         allScreens: Bool = true,
         sensitivity: PetSensitivity = .normal,
         showsProfileBackdrop: Bool = false) {
        self.speciesSlug = speciesSlug
        self.size = size
        self.anchor = anchor
        self.allScreens = allScreens
        self.sensitivity = sensitivity
        self.showsProfileBackdrop = showsProfileBackdrop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speciesSlug = try c.decode(String.self, forKey: .speciesSlug)
        size = try c.decodeIfPresent(PetSize.self, forKey: .size) ?? .medium
        anchor = try c.decodeIfPresent(PetAnchor.self, forKey: .anchor) ?? .bottomTrailing
        allScreens = try c.decodeIfPresent(Bool.self, forKey: .allScreens) ?? true
        sensitivity = try c.decodeIfPresent(PetSensitivity.self, forKey: .sensitivity) ?? .normal
        showsProfileBackdrop = try c.decodeIfPresent(Bool.self, forKey: .showsProfileBackdrop) ?? false
    }
}

enum PetAccess {
    static func requiresPaywall(pet: PetSpecies, state: SubscriptionState, ownedIDs: Set<Int>) -> Bool {
        if let id = pet.remoteID, ownedIDs.contains(id) { return false }
        return requiresPro(state)
    }

    static func submissionNeedsPurchase(credits: Int) -> Bool {
        credits < 1
    }

    private static func requiresPro(_ state: SubscriptionState) -> Bool {
        guard !state.isPro, case .free = state else { return false }
        return true
    }
}

enum PetSubmissionStatus: String, Codable, Sendable {
    case inReview
    case ready
    case rejected
}

enum PetSubmissionAge {
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    static func isStale(submittedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(submittedAt) > staleAfter
    }
}

enum PetSubmissionOutcome: Equatable, Sendable {
    case stillPending
    case approved
    case rejected(reason: String?)
    case unrecognized(String)

    static let maxReasonLength = 500

    static func parse(_ data: Data) -> PetSubmissionOutcome {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let id: Int?
                let status: String?
                let message: String?
                let rejectionReason: String?

                enum CodingKeys: String, CodingKey {
                    case id, status, message
                    case rejectionReason = "rejection_reason"
                }
            }
            let status: String?
            let data: Payload?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .unrecognized(snippet(data))
        }
        if let explicit = envelope.data?.status?.lowercased() {
            switch explicit {
            case "approved", "published", "live": return .approved
            case "rejected", "declined":
                return .rejected(reason: envelope.data?.rejectionReason.map { String($0.prefix(maxReasonLength)) })
            case "pending", "processing", "review", "in_review", "queued": return .stillPending
            default: return .unrecognized(explicit)
            }
        }
        if envelope.status == "success", envelope.data?.id != nil { return .approved }
        if envelope.status == "error", let message = envelope.data?.message,
           message.localizedCaseInsensitiveContains("not found") {
            return .stillPending
        }
        return .unrecognized(envelope.data?.message ?? snippet(data))
    }

    private static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }
}

struct PetsState: Codable, Sendable {
    var version: Int = 1
    var placement: PetPlacement?
}
