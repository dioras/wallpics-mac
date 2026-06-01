import SwiftUI
import StoreKit

struct PaywallScreen: View {
    @Environment(StoreKitService.self) private var store
    var onDone: () -> Void
    var onSkip: () -> Void

    @State private var selectedProductID: String?
    @State private var appeared = false
    @State private var didAttemptLoad = false
    // Soft paywall: the dismiss (✕) is withheld for a few seconds so the offer is seen first,
    // then fades in. Lets the user close the screen without committing.
    @State private var showCloseButton = false
    private let closeButtonDelay: Duration = .seconds(3)

    // Replace with the real privacy + terms URLs from App Store Connect before submission.
    // App Store review requires both links to be reachable from the paywall.
    private let privacyURL = URL(string: "https://wallpics.app/privacy")!
    private let termsURL = URL(string: "https://wallpics.app/terms")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    header
                    benefits
                    productPicker
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(AmbientBackdrop())
        .overlay(alignment: .topTrailing) { closeButton }
        .task {
            withAnimation(Motion.transition) { appeared = true }
            await store.loadProducts()
            selectProduct()
            didAttemptLoad = true
        }
        .task {
            try? await Task.sleep(for: closeButtonDelay)
            withAnimation(.easeInOut(duration: 0.35)) { showCloseButton = true }
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if showCloseButton {
            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(Theme.Space.l)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .help(String(localized: "Close"))
            .accessibilityLabel(String(localized: "Close"))
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.m) {
            AppIconView(size: 88)
            Text("Unlock WallPics Pro")
                .font(.system(size: 28, weight: .bold))
            Text("Remove the watermark and support a small, independent team.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.top, Theme.Space.l)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Benefit(symbol: "drop.degreesign", text: "No watermark on any wallpaper", index: 0, appeared: appeared)
            Benefit(symbol: "rectangle.stack.fill", text: "Full 4K library, no daily limits", index: 1, appeared: appeared)
            Benefit(symbol: "bolt.fill", text: "Priority access to new drops", index: 2, appeared: appeared)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var productPicker: some View {
        VStack(spacing: Theme.Space.m) {
            if !store.products.isEmpty {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                    ProductRow(
                        product: product,
                        isSelected: selectedProductID == product.id,
                        isBestValue: product.id == bestValueID
                    ) {
                        withAnimation(Motion.hover) { selectedProductID = product.id }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(Motion.transition.delay(0.08 * Double(index)), value: appeared)
                }
            } else if didAttemptLoad {
                storeUnavailable
            } else {
                ProgressView().controlSize(.large).padding(.vertical, 40)
            }
        }
    }

    private var storeUnavailable: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Plans couldn't load right now.")
                .font(.callout.weight(.medium))
            Text("Check your connection and try again — you can keep using the free version in the meantime.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Try Again") {
                Task {
                    didAttemptLoad = false
                    await store.loadProducts()
                    selectProduct()
                    didAttemptLoad = true
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, Theme.Space.xl)
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.m) {
            if selectedProduct == nil && didAttemptLoad {
                // No store products available — let the user proceed on the free tier.
                Button("Continue with Free", action: onSkip)
                    .buttonStyle(.primaryCTA)
                    .frame(maxWidth: 420)
            } else {
                Button(action: subscribe) {
                    Text(subscribeButtonTitle)
                }
                .buttonStyle(.primaryCTA)
                .frame(maxWidth: 420)
                .disabled(selectedProductID == nil || store.isPurchasing)
            }

            if let renewalNote {
                Text(renewalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Space.l) {
                Button("Restore") { Task { await store.restore() } }
                Button("Privacy") { NSWorkspace.shared.open(privacyURL) }
                Button("Terms") { NSWorkspace.shared.open(termsURL) }
                Button("Maybe Later", action: onSkip)
            }
            .buttonStyle(.borderless)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.xl)
        .background(.thinMaterial)
    }

    /// The longest-period product (e.g. yearly) gets the "Best value" badge and is preselected.
    private var bestValueID: String? {
        store.products.max { StoreKitService.periodSeconds($0) < StoreKitService.periodSeconds($1) }?.id
    }

    private func selectProduct() {
        selectedProductID = bestValueID ?? store.products.first?.id
    }

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID }
    }

    private var subscribeButtonTitle: String {
        guard let product = selectedProduct else { return String(localized: "Continue") }
        if hasFreeTrial(product) {
            return String(localized: "Start Free Trial")
        }
        return String(localized: "Subscribe for \(product.displayPrice)")
    }

    private var renewalNote: String? {
        guard let product = selectedProduct else { return nil }
        if hasFreeTrial(product), let trial = trialDescription(product) {
            return String(localized: "\(trial) free, then \(product.displayPrice). Cancel anytime.")
        }
        return String(localized: "\(product.displayPrice), auto-renews. Cancel anytime.")
    }

    private func hasFreeTrial(_ product: Product) -> Bool {
        product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    /// Human-readable trial length, e.g. "3 days" / "1 week".
    private func trialDescription(_ product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer else { return nil }
        let n = offer.period.value
        switch offer.period.unit {
        case .day: return n == 1 ? String(localized: "1 day") : String(localized: "\(n) days")
        case .week: return n == 1 ? String(localized: "1 week") : String(localized: "\(n) weeks")
        case .month: return n == 1 ? String(localized: "1 month") : String(localized: "\(n) months")
        case .year: return n == 1 ? String(localized: "1 year") : String(localized: "\(n) years")
        @unknown default: return nil
        }
    }

    private func subscribe() {
        guard let product = selectedProduct else { return }
        Task {
            let success = await store.purchase(product)
            if success { onDone() }
        }
    }
}

private struct Benefit: View {
    let symbol: String
    let text: LocalizedStringKey
    let index: Int
    let appeared: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(Theme.accent)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            Text(text).font(.callout)
            Spacer()
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -12)
        .animation(Motion.transition.delay(0.05 * Double(index)), value: appeared)
    }
}

private struct ProductRow: View {
    let product: Product
    let isSelected: Bool
    let isBestValue: Bool
    var onSelect: () -> Void

    /// Per-period suffix shown next to the price, e.g. "/ week", "/ year".
    ///
    /// App Store Connect can encode the same duration different ways — a weekly plan may come
    /// back as "1 week" *or* "7 days". We normalize so a 7-day period reads "/ week" (and 30-day
    /// → "/ month", 365-day → "/ year") instead of the misleading "/ day" the client reported.
    private var periodSuffix: String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        let unit: Product.SubscriptionPeriod.Unit
        switch (period.unit, period.value) {
        case (.day, 7):   unit = .week
        case (.day, 30):  unit = .month
        case (.day, 365): unit = .year
        default:          unit = period.unit
        }
        switch unit {
        case .day: return String(localized: "/ day")
        case .week: return String(localized: "/ week")
        case .month: return String(localized: "/ month")
        case .year: return String(localized: "/ year")
        @unknown default: return ""
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text(product.displayName)
                            .font(.headline)
                        if isBestValue {
                            Text("Best value")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 2) {
                    Text(product.displayPrice)
                        .font(.headline.monospacedDigit())
                    Text(periodSuffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            }
            .padding(Theme.Space.l)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.separator),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: isSelected ? Theme.accent.opacity(0.25) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}
