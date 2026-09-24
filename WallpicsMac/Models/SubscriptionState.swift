import Foundation

enum SubscriptionState: Equatable {
    case unknown
    case free
    case trial(expiresAt: Date)
    case pro(expiresAt: Date?)

    var isPro: Bool {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "debugFreeTier") else { return true }
        switch self {
        case .pro, .trial: return true
        case .free, .unknown: return false
        }
        #else
        switch self {
        case .pro, .trial: return true
        case .free, .unknown: return false
        }
        #endif
    }

    var requiresWatermark: Bool { !isPro }

    var expiresAt: Date? {
        switch self {
        case .trial(let date): return date
        case .pro(let date): return date
        case .free, .unknown: return nil
        }
    }
}
