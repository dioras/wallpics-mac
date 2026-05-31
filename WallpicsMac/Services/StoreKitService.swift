import Foundation
import StoreKit
import Observation


enum ProductIDs {
    // Exact App Store Connect product IDs. Two auto-renewable subscriptions only.
    static let weekly = "macos_weekly"
    static let yearly = "macos_yearly"
    static let all: [String] = [weekly, yearly]
}

@MainActor
@Observable
final class StoreKitService {
    static let shared = StoreKitService()

    var products: [Product] = []
    var state: SubscriptionState = .unknown
    var isPurchasing = false
    var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    func bootstrap() {
        Task { await loadProducts() }
        Task { await refreshEntitlements() }
        startListeningForUpdates()
    }

    // MARK: - Products

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ProductIDs.all)
            // Sort by subscription period, shortest first (weekly → yearly), so the
            // paywall order is correct no matter which IDs the store actually returns.
            products = fetched.sorted { Self.periodSeconds($0) < Self.periodSeconds($1) }
            Log.store.info("Loaded \(fetched.count) products")
        } catch {
            lastError = error.localizedDescription
            Log.store.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Purchases

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard let transaction = Self.verify(verification) else { return false }
                await transaction.finish()
                await refreshEntitlements()
                return true
            case .userCancelled:
                return false
            case .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            Log.store.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
            Log.store.error("Restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Entitlements

    func refreshEntitlements() async {
        var newState: SubscriptionState = .free
        for await result in Transaction.currentEntitlements {
            guard let transaction = Self.verify(result) else { continue }
            guard ProductIDs.all.contains(transaction.productID) else { continue }
            // All products are auto-renewable subscriptions (weekly / yearly).
            if let expires = transaction.expirationDate, expires > Date() {
                let isTrial = transaction.offerType == .introductory
                newState = isTrial ? .trial(expiresAt: expires) : .pro(expiresAt: expires)
            } else if transaction.expirationDate == nil {
                // Safety net for a non-expiring entitlement, should the catalog ever change.
                newState = .pro(expiresAt: nil)
            }
        }
        state = newState
    }

    /// Length of a product's subscription period in seconds (0 if it isn't a subscription).
    nonisolated static func periodSeconds(_ product: Product) -> Double {
        guard let period = product.subscription?.subscriptionPeriod else { return 0 }
        let unit: Double
        switch period.unit {
        case .day: unit = 86_400
        case .week: unit = 604_800
        case .month: unit = 2_592_000
        case .year: unit = 31_536_000
        @unknown default: unit = 0
        }
        return unit * Double(period.value)
    }

    private func startListeningForUpdates() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = Self.verify(result) {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    private nonisolated static func verify<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let value): return value
        case .unverified: return nil
        }
    }
}
