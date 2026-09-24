import SwiftUI
import StoreKit

struct PaywallScreen: View {
    @Environment(StoreKitService.self) private var store
    var onDone: () -> Void
    var onSkip: () -> Void
    var animatesIn: Bool = true
    var compact: Bool = false
    var onOpenDIY: (() -> Void)? = nil

    @State private var selectedProductID: String?
    @State private var appeared = false
    @State private var didAttemptLoad = false
    @State private var isRestoring = false
    @State private var purchaseNote: String?
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
            ViewThatFits(in: .vertical) {
                offer(stageHeight: compact ? 250 : 280)
                offer(stageHeight: compact ? 190 : 220)
                offer(stageHeight: compact ? 140 : 160)
                offer(stageHeight: compact ? 140 : 160, showsFeatures: false)
                ScrollView { offer(stageHeight: compact ? 140 : 160) }
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0.9),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .background {
            ZStack {
                Color.black
                RadialGradient(colors: [.white.opacity(0.08), .clear],
                               center: .top, startRadius: 0, endRadius: 560)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) { closeButton }
        .onAppear {
            if !animatesIn { appeared = true }
        }
        .task {
            if animatesIn {
                withAnimation(Motion.transition) { appeared = true }
            }
            print("[Paywall] 🟡 .task fired — calling loadProducts()")
            await store.loadProducts()
            print("[Paywall] 🟢 loadProducts() returned. store.products.count=\(store.products.count) lastError=\(store.lastError ?? "nil")")
            selectProduct()
            print("[Paywall] 🟢 selectedProductID=\(selectedProductID ?? "nil")")
            didAttemptLoad = true
            await store.loadDIYPetProduct()
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
            .padding(.top, Theme.Space.l + DesktopMenuBar.height + Theme.Space.s)
            .padding(.trailing, Theme.Space.l + Theme.Space.s)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .help(String(localized: "Close"))
            .accessibilityLabel(String(localized: "Close"))
        }
    }

    private func offer(stageHeight: CGFloat, showsFeatures: Bool = true) -> some View {
        VStack(spacing: compact ? Theme.Space.l : Theme.Space.xl) {
            PaywallStage(pets: stagePets, height: stageHeight)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: compact ? Theme.Space.l : Theme.Space.xl) {
                header
                if showsFeatures {
                    features
                }
                productPicker
                diyOffer
            }
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: 480)
        }
        .padding(.top, Theme.Space.l)
        .padding(.bottom, compact ? Theme.Space.l : Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.28), value: store.products.count)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            Text(verbatim: "PRO")
                .font(.system(size: 10, weight: .heavy))
                .kerning(2.5)
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white, in: Capsule())
            Text("Unlock WallPics Pro")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Every wallpaper, every pet, no watermark.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .padding(.top, 0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    private var features: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            BenefitBadge(symbol: "play.rectangle.fill", text: String(localized: "1,000+ live & 4K wallpapers"))
            BenefitBadge(symbol: "pawprint.fill", text: String(localized: "Every desktop pet"))
            BenefitBadge(symbol: "drop.degreesign", text: String(localized: "No watermark"))
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(Motion.transition.delay(0.06), value: appeared)
    }

    private var diyPriceText: String {
        store.diyPetProduct.map { String(localized: "One-time purchase · \($0.displayPrice)") }
            ?? String(localized: "Sold separately")
    }

    @ViewBuilder
    private var diyOffer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Also available")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
            let row = HStack(spacing: Theme.Space.s) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))
                if let poster = stagePets.first.flatMap({ PetPosterCache.image(for: $0.posterURL) }) {
                    Image(nsImage: poster)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 34)
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Make your own pet from photos")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(diyPriceText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                if onOpenDIY != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(Theme.Space.s)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            )
            if let onOpenDIY {
                Button(action: onOpenDIY) { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open DIY Pet"))
            } else {
                row
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(appeared ? 1 : 0)
    }

    private static let featuredPetIDs = [12, 41, 43, 22, 40]

    private var stagePets: [PetSpecies] {
        let all = RemotePetService.shared.pets
        let featured = Self.featuredPetIDs.compactMap { id in all.first { $0.remoteID == id } }
        guard featured.isEmpty else { return featured }
        let community = RemotePetService.shared.communityIDs
        return Array(all.filter { !($0.remoteID.map(community.contains) ?? false) }.prefix(5))
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
        VStack(spacing: compact ? Theme.Space.s : Theme.Space.m) {
            if selectedProduct == nil && didAttemptLoad {
                whitePill(String(localized: "Continue with Free"), action: onSkip)
            } else {
                whitePill(subscribeButtonTitle, busy: store.isPurchasing, action: subscribe)
                    .disabled(selectedProductID == nil || store.isPurchasing || isRestoring)
            }

            if let renewalNote {
                Text(renewalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let purchaseNote {
                Text(purchaseNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Space.l) {
                Button(isRestoring ? String(localized: "Restoring…") : String(localized: "Restore"), action: restore)
                    .disabled(isRestoring || store.isPurchasing)
                Button("Privacy") { NSWorkspace.shared.open(privacyURL) }
                Button("Terms") { NSWorkspace.shared.open(termsURL) }
                Button("Maybe Later", action: onSkip)
            }
            .buttonStyle(.borderless)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, compact ? Theme.Space.l : Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, Color(red: 0.05, green: 0.03, blue: 0.09).opacity(0.85)],
                           startPoint: .top, endPoint: .center)
        )
    }

    private func whitePill(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(title).font(.system(.headline, design: .rounded).weight(.heavy))
            }
            .frame(maxWidth: 420)
            .padding(.vertical, 14)
            .foregroundStyle(.black)
            .background(.white, in: Capsule())
            .shadow(color: .white.opacity(0.12), radius: 16, y: 4)
        }
        .buttonStyle(.plain)
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
            purchaseNote = nil
            let success = await store.purchase(product)
            if success { onDone() } else { purchaseNote = store.lastError }
        }
    }

    private func restore() {
        Task {
            isRestoring = true
            purchaseNote = nil
            await store.restore()
            isRestoring = false
            if store.state.isPro {
                onDone()
            } else {
                purchaseNote = store.lastError ?? String(localized: "No purchases found to restore.")
            }
        }
    }
}

private struct PaywallClip {
    let file: String
    let title: String

    static let all: [PaywallClip] = [
        PaywallClip(file: "gojo", title: "Satoru Gojo Six Eyes"),
        PaywallClip(file: "skyline", title: "Skyline R34"),
        PaywallClip(file: "spiderman", title: "Spider-Man Red Suit"),
        PaywallClip(file: "knight", title: "Crimson Knight"),
        PaywallClip(file: "sasuke", title: "Sasuke Rinnegan"),
        PaywallClip(file: "goku", title: "Goku Ascent")
    ].filter { $0.videoURL != nil }

    var videoURL: URL? { Bundle.main.url(forResource: file, withExtension: "mp4", subdirectory: "PaywallClips") }

    var poster: NSImage? {
        Bundle.main.url(forResource: file, withExtension: "jpg", subdirectory: "PaywallClips").flatMap(NSImage.init(contentsOf:))
    }
}

private struct PaywallStage: View {
    let pets: [PetSpecies]
    let height: CGFloat

    @State private var slide = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let clips = PaywallClip.all
    private static let posters: [String: NSImage] = Dictionary(
        uniqueKeysWithValues: clips.compactMap { clip in clip.poster.map { (clip.file, $0) } })

    private var clip: PaywallClip? { Self.clips.isEmpty ? nil : Self.clips[slide % Self.clips.count] }
    private var pet: PetSpecies? { pets.isEmpty ? nil : pets[(slide / 2) % pets.count] }

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop
            VStack(spacing: 0) {
                DesktopMenuBar()
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if let clip {
                        liveChip(clip)
                    }
                    if Self.clips.count > 1 {
                        dock
                    }
                }
                .padding(.leading, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
                Spacer(minLength: 0)
                if let pet {
                    petView(pet)
                        .padding(.trailing, Theme.Space.l)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
        .padding(.horizontal, Theme.Space.l)
        .task(id: pets.map(\.slug)) { await cycle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live wallpapers with a desktop pet that follows your cursor"))
    }

    private func cycle() async {
        guard !reduceMotion, Self.clips.count > 1 || pets.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.9)) { slide += 1 }
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(white: 0.06)
            if let clip, let url = clip.videoURL {
                HeroVideoPlayer(url: url)
                    .id(clip.file)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func liveChip(_ clip: PaywallClip) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text(verbatim: "LIVE")
                .font(.system(size: 9, weight: .heavy))
                .kerning(1)
            Text(verbatim: clip.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .id(clip.file)
        .transition(.opacity)
    }

    private var dock: some View {
        let active = Self.clips.isEmpty ? 0 : slide % Self.clips.count
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(Self.clips.enumerated()), id: \.element.file) { index, item in
                Group {
                    if let image = Self.posters[item.file] {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 38, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(index == active ? 0.95 : 0.15), lineWidth: index == active ? 1.5 : 0.5)
                )
                .scaleEffect(index == active ? 1.25 : 1, anchor: .bottom)
                .offset(y: index == active ? -3 : 0)
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .animation(Motion.reward, value: slide)
    }

    private func petView(_ pet: PetSpecies) -> some View {
        let petHeight = height * 0.8
        let petWidth = petHeight * pet.aspectRatio
        return PetPreviewView(species: pet)
            .frame(width: petWidth, height: petHeight)
            .offset(y: petHeight * (1 - pet.subjectBottom))
            .id(pet.slug)
            .transition(.opacity)
    }
}

private struct BenefitBadge: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
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
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .padding(Theme.Space.l)
            .background(.white.opacity(isSelected ? 0.10 : 0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.10)),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: .black.opacity(isSelected ? 0.45 : 0.15), radius: isSelected ? 14 : 6, y: 5)
            .scaleEffect(isSelected ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: isSelected)
    }
}
