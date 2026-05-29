import Foundation
import StoreKit
import Observation


enum ProductIDs {
    static let monthly = "com.wallpics.mac.pro.monthly"
    static let yearly = "com.wallpics.mac.pro.yearly"
    static let lifetime = "com.wallpics.mac.pro.lifetime"
    static let all: [String] = [monthly, yearly, lifetime]
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
            products = fetched.sorted { lhs, rhs in
                ProductIDs.all.firstIndex(of: lhs.id) ?? .max <
                ProductIDs.all.firstIndex(of: rhs.id) ?? .max
            }
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
            if ProductIDs.all.contains(transaction.productID) {
                if transaction.productID == ProductIDs.lifetime {
                    newState = .pro(expiresAt: nil)
                    break
                }
                if let expires = transaction.expirationDate, expires > Date() {
                    let isTrial = transaction.offerType == .introductory
                    newState = isTrial ? .trial(expiresAt: expires) : .pro(expiresAt: expires)
                }
            }
        }
        state = newState
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
