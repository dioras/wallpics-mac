import SwiftUI

struct OnboardingFlow: View {
    var onDone: () -> Void
    @State private var step: Step = .welcome
    @State private var pickedWallpaper: Wallpaper?
    @State private var showcase: [Wallpaper] = []
    @State private var freePicks: [Wallpaper] = []
    @State private var loadFailed = false
    @State private var isLoading = false

    private static let showcaseCount = 5
    private static let pickCount = 12
    private static let pageSize = 60
    private static let maxPages = 3

    enum Step: Int, CaseIterable { case welcome, pick, set, paywall }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, Theme.Space.xxl)
                    .transition(stepTransition)
                    .id(step)

                if step != .paywall {
                    StepIndicator(current: step)
                        .padding(.bottom, Theme.Space.xl)
                }
            }

            if step != .paywall {
                Button("Skip", action: onDone)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .help(String(localized: "Skip the intro and go straight to the app"))
            }
        }
        .task { await loadSamples() }
        .task(id: loadFailed) {
            while loadFailed && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await loadSamples()
            }
        }
        .animation(Motion.transition, value: step)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStep(samples: showcase) { advance(to: .pick) }
        case .pick:
            PickStep(samples: freePicks, picked: $pickedWallpaper, loadFailed: loadFailed, isLoading: isLoading,
                     onRetry: { Task { await loadSamples() } }, onSkip: onDone) {
                if pickedWallpaper != nil { advance(to: .set) }
            }
        case .set:
            SetStep(wallpaper: pickedWallpaper) { advance(to: .paywall) }
        case .paywall:
            PaywallScreen(onDone: onDone, onSkip: onDone)
                .padding(.horizontal, -Theme.Space.xxl) // paywall manages its own insets
        }
    }

    private func advance(to step: Step) {
        withAnimation(Motion.transition) { self.step = step }
    }

    private func loadSamples() async {
        guard freePicks.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let timestamp = Int(Date().timeIntervalSince1970)
        var popular: [Wallpaper] = []
        var free: [Wallpaper] = []
        for page in 1...Self.maxPages {
            do {
                let result = try await WallpaperAPI.shared.desktopWallpapers(page: page, perPage: Self.pageSize,
                                                                             sortOrder: .popular, timestamp: timestamp)
                popular.append(contentsOf: result.data)
                free.append(contentsOf: result.data.filter { !$0.isPremiumContent })
                showcase = Array(popular.prefix(Self.showcaseCount))
                freePicks = Array((free.isEmpty ? popular : free).prefix(Self.pickCount))
                if free.count >= Self.pickCount || result.data.count < Self.pageSize { break }
            } catch {
                Log.ui.error("Onboarding samples page \(page) failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        loadFailed = freePicks.isEmpty
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let samples: [Wallpaper]
    var onContinue: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: 0)

            AppIconView(size: 72)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.8)

            VStack(spacing: Theme.Space.s) {
                Text("Welcome to WallPics")
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Stunning 4K wallpapers, hand-picked and refreshed daily.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Spacer(minLength: Theme.Space.xl)

            FloatingCollage(samples: samples)
                .frame(height: 210)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.92)

            Spacer(minLength: 0)

            Button("Get Started", action: onContinue)
                .buttonStyle(.primaryCTA)
                .frame(maxWidth: 320)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
        }
        .padding(.vertical, Theme.Space.xxl)
        .onAppear {
            withAnimation(Motion.transition.delay(0.05)) { appeared = true }
        }
    }
}

/// A fanned, gently floating stack of real wallpaper thumbnails. The product sells itself.
private struct FloatingCollage: View {
    let samples: [Wallpaper]
    @State private var float = false

    private let layout: [(angle: Double, x: CGFloat, y: CGFloat, scale: CGFloat)] = [
        (-12, -150, 14, 0.86),
        (-6, -78, -8, 0.94),
        (0, 0, -16, 1.04),
        (6, 78, -8, 0.94),
        (12, 150, 14, 0.86)
    ]

    var body: some View {
        ZStack {
            if samples.isEmpty {
                ForEach(0..<5, id: \.self) { i in
                    card(index: i, content: AnyView(placeholder))
                }
            } else {
                ForEach(Array(samples.prefix(5).enumerated()), id: \.element.id) { i, wallpaper in
                    card(index: i, content: AnyView(
                        ThumbnailView(url: wallpaper.thumbnailURL,
                                      placeholderTint: WallpaperCard.tint(for: wallpaper.id))
                    ))
                }
            }
        }
        .onAppear { float = true }
    }

    private func card(index i: Int, content: AnyView) -> some View {
        let cfg = layout[min(i, layout.count - 1)]
        return content
            .frame(width: 116, height: 188)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 10)
            .scaleEffect(cfg.scale)
            .rotationEffect(.degrees(cfg.angle))
            .offset(x: cfg.x, y: cfg.y + (float ? -6 : 6))
            .zIndex(cfg.scale)
            .animation(
                .easeInOut(duration: 3.2 + Double(i) * 0.25).repeatForever(autoreverses: true),
                value: float
            )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(Color.primary.opacity(0.08))
    }
}

// MARK: - Pick

private struct PickStep: View {
    let samples: [Wallpaper]
    @Binding var picked: Wallpaper?
    var loadFailed = false
    var isLoading = false
    var onRetry: () -> Void = {}
    var onSkip: () -> Void = {}
    var onContinue: () -> Void

    // 16:9 landscape cards in a vertically-scrolling grid (desktop wallpapers are landscape).
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: Theme.Space.m)]

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.s) {
                Text("Pick your first wallpaper")
                    .font(.system(size: 26, weight: .bold))
                Text("On us — no strings attached.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Theme.Space.l)

            if samples.isEmpty {
                VStack(spacing: Theme.Space.m) {
                    Spacer(minLength: 0)
                    if loadFailed {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Couldn't load wallpapers")
                            .font(.title3.weight(.semibold))
                        Text("Check your internet connection. We'll keep trying automatically.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: Theme.Space.m) {
                            Button(action: onRetry) {
                                HStack(spacing: Theme.Space.s) {
                                    if isLoading { ProgressView().controlSize(.small) }
                                    Text("Try Again")
                                }
                            }
                            .disabled(isLoading)
                            Button("Skip for now", action: onSkip)
                        }
                        .controlSize(.large)
                    } else {
                        ProgressView()
                        Text("Loading wallpapers…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Theme.Space.m) {
                        ForEach(samples) { wallpaper in
                            PickCard(wallpaper: wallpaper, isSelected: picked?.id == wallpaper.id) {
                                withAnimation(Motion.hover) { picked = wallpaper }
                            }
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .padding(.horizontal, -Theme.Space.m)
                .frame(maxHeight: .infinity)
            }

            Button("Continue", action: onContinue)
                .buttonStyle(.primaryCTA)
                .frame(maxWidth: 320)
                .disabled(picked == nil)
                .opacity(picked == nil ? 0.5 : 1)
                .padding(.bottom, Theme.Space.l)
        }
    }
}

private struct PickCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ThumbnailView(url: wallpaper.thumbnailURL,
                          placeholderTint: WallpaperCard.tint(for: wallpaper.id))
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .white.opacity(hovering ? 0.2 : 0.08),
                                      lineWidth: isSelected ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, Theme.accent)
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(isSelected ? 1.03 : (hovering ? 1.015 : 1))
                .shadow(color: .black.opacity(isSelected ? 0.4 : 0.2), radius: isSelected ? 16 : 8, y: 6)
                // Whole card is one instant hit/hover target, regardless of image load state.
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: isSelected)
        .animation(Motion.hover, value: hovering)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Set

private struct SetStep: View {
    let wallpaper: Wallpaper?
    var onContinue: () -> Void
    @State private var isSetting = false
    @State private var applied = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: 0)

            SuccessGlyph(done: applied)

            VStack(spacing: Theme.Space.s) {
                Text(applied ? String(localized: "All set.") : String(localized: "Make it yours"))
                    .font(.system(size: 26, weight: .bold))
                Text(applied
                     ? String(localized: "Take a peek at your desktop — that's your new wallpaper.")
                     : String(localized: "We'll apply your pick right now so you can see it live."))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }

            Spacer(minLength: 0)

            Button {
                if applied { onContinue() }
                else if let wallpaper { Task { await applyAndAdvance(wallpaper) } }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    if isSetting {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(applied ? String(localized: "Continue") : (isSetting ? String(localized: "Applying…") : String(localized: "Apply Wallpaper")))
                }
            }
            .buttonStyle(.primaryCTA)
            .frame(maxWidth: 320)
            .disabled(isSetting)
        }
        .padding(.vertical, Theme.Space.xxl)
    }

    private func applyAndAdvance(_ wallpaper: Wallpaper) async {
        guard let url = wallpaper.wallpaperURL else {
            errorMessage = String(localized: "This wallpaper isn't available right now.")
            return
        }
        isSetting = true
        errorMessage = nil
        defer { isSetting = false }
        do {
            let isPro = StoreKitService.shared.state.isPro
            let imagesDir = await CacheManager.shared.folderURL(.images)
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let original = imagesDir.appendingPathComponent("\(wallpaper.id)-full.\(ext)")
            if !FileManager.default.fileExists(atPath: original.path) {
                let downloaded = try await WallpaperAPI.shared.downloadImage(from: url)
                try? FileManager.default.removeItem(at: original)
                try FileManager.default.moveItem(at: downloaded, to: original)
            }
            let variant = isPro ? "pro" : "free"
            let destination = imagesDir.appendingPathComponent("\(wallpaper.id)-\(variant).jpg")
            try WatermarkService.applyIfNeeded(to: original, destinationURL: destination, isPro: isPro, appIcon: NSApplication.shared.applicationIconImage, screenAspects: NSScreen.screens.map { $0.frame.width / max(1, $0.frame.height) })
            await CacheManager.shared.pinOnly([wallpaper.id])
            WallpaperRenderer.shared.setStaticImage(destination, source: original, watermarked: !isPro)
            await WallpaperAPI.shared.recordDownload(wallpaperID: wallpaper.id)
            withAnimation(Motion.reward) { applied = true }
        } catch {
            Log.ui.error("Onboarding set failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = String(localized: "Couldn't apply the wallpaper. Check your connection and try again, or skip for now.")
        }
    }
}

private struct SuccessGlyph: View {
    let done: Bool
    var body: some View {
        ZStack {
            Circle()
                .fill((done ? Color.green : Theme.accent).opacity(0.15))
                .frame(width: 120, height: 120)
            Image(systemName: done ? "checkmark.seal.fill" : "wand.and.stars")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(done ? Color.green : Theme.accent)
                .modifier(GlyphAnimation(done: done))
        }
    }
}

private struct GlyphAnimation: ViewModifier {
    let done: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.bounce, value: done)
        } else {
            content.scaleEffect(done ? 1.0 : 1.0)
        }
    }
}

// MARK: - Step indicator

private struct StepIndicator: View {
    let current: OnboardingFlow.Step
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(OnboardingFlow.Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .frame(width: s == current ? 22 : 8, height: 8)
                    .animation(Motion.hover, value: current)
            }
        }
    }
}
