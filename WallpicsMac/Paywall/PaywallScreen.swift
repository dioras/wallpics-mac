import SwiftUI
import StoreKit

struct PaywallScreen: View {
    @Environment(StoreKitService.self) private var store
    var onDone: () -> Void
    var onSkip: () -> Void

    @State private var selectedProductID: String?
    @State private var appeared = false
    @State private var didAttemptLoad = false

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
        .task {
            withAnimation(Motion.transition) { appeared = true }
            await store.loadProducts()
            selectProduct()
            didAttemptLoad = true
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
                        isYearly: product.id == ProductIDs.yearly
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

    private func selectProduct() {
        selectedProductID = store.products.first { $0.id == ProductIDs.yearly }?.id ?? store.products.first?.id
    }

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID }
    }

    private var subscribeButtonTitle: String {
        guard let product = selectedProduct else { return String(localized: "Continue") }
        if product.id == ProductIDs.lifetime {
            return String(localized: "Buy \(product.displayPrice)")
        }
        if product.subscription?.introductoryOffer?.paymentMode == .freeTrial {
            return String(localized: "Start Free Trial")
        }
        return String(localized: "Subscribe for \(product.displayPrice)")
    }

    private var renewalNote: String? {
        guard let product = selectedProduct, product.id != ProductIDs.lifetime else { return nil }
        if product.subscription?.introductoryOffer?.paymentMode == .freeTrial {
            return String(localized: "7 days free, then \(product.displayPrice). Cancel anytime.")
        }
        return String(localized: "\(product.displayPrice), auto-renews. Cancel anytime.")
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
    let isYearly: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text(product.displayName)
                            .font(.headline)
                        if isYearly {
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
                Text(product.displayPrice)
                    .font(.headline.monospacedDigit())
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            }
            .padding(Theme.Space.l)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .white.opacity(0.06), lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: isSelected ? Theme.accent.opacity(0.25) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}
