import Foundation

enum SubscriptionState: Equatable {
    case unknown
    case free
    case trial(expiresAt: Date)
    case pro(expiresAt: Date?)

    var isPro: Bool {
        switch self {
        case .pro, .trial: return true
        case .free, .unknown: return false
        }
    }

    var requiresWatermark: Bool { !isPro }
}
