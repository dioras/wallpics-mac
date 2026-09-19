import Foundation
import Observation

enum WallpaperAccess {
    static let freeSetsPerDay = 3

    enum Reason: Equatable, Sendable {
        case premiumContent
        case dailyLimit
    }

    enum Decision: Equatable, Sendable {
        case allowed
        case paywall(Reason)
    }

    static func decision(isPremium: Bool, state: SubscriptionState, setsToday: Int) -> Decision {
        guard !state.isPro, case .free = state else { return .allowed }
        if isPremium { return .paywall(.premiumContent) }
        if setsToday >= freeSetsPerDay { return .paywall(.dailyLimit) }
        return .allowed
    }
}

@MainActor
@Observable
final class WallpaperSetQuota {
    static let shared = WallpaperSetQuota()

    private static let dayKey = "freeWallpaperSetsDay"
    private static let countKey = "freeWallpaperSetsCount"

    private(set) var setsToday = 0

    private let defaults: UserDefaults
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        setsToday = Self.count(storedDay: defaults.string(forKey: Self.dayKey),
                               storedCount: defaults.integer(forKey: Self.countKey),
                               today: Self.today())
    }

    func recordSet() {
        refresh()
        setsToday += 1
        defaults.set(Self.today(), forKey: Self.dayKey)
        defaults.set(setsToday, forKey: Self.countKey)
    }

    nonisolated static func count(storedDay: String?, storedCount: Int, today: String) -> Int {
        storedDay == today ? max(storedCount, 0) : 0
    }

    nonisolated static func today(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
