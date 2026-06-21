import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var browseModel = BrowseViewModel()
    @State private var favoritesModel = FavoritesViewModel()
    @State private var widgetsModel = WidgetsViewModel()

    var body: some View {
        @Bindable var env = env
        ZStack(alignment: .top) {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(favoritesModel)
            LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.28), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
            TopNavBar(selection: $env.selectedSection, query: $browseModel.query)
        }
        .overlay {
            if let wallpaper = env.detailWallpaper {
                DetailOverlay(wallpaper: wallpaper, list: browseModel.filteredWallpapers) {
                    withAnimation(Motion.transition) { env.detailWallpaper = nil }
                } onShow: { next in
                    env.detailWallpaper = next
                }
                .environment(favoritesModel)
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(Motion.transition, value: env.detailWallpaper?.id)
        .onChange(of: browseModel.query) { _, newValue in
            if !newValue.isEmpty && env.selectedSection != .browse {
                env.selectedSection = .browse
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("WallPics")
        .environment(\.locale, LanguageController.locale(for: env.settings.languageCode))
        .task {
            // Present onboarding first, independent of the (possibly slow) network load, and
            // on the next runloop tick so the window is fully mounted before the sheet shows.
            if !OnboardingPresenter.hasCompleted {
                await Task.yield()
                env.showOnboarding = true
            }
            await browseModel.loadFirstPageIfNeeded()
            await favoritesModel.refresh()
        }
        .sheet(isPresented: $env.showOnboarding) {
            OnboardingFlow {
                OnboardingPresenter.markCompleted()
                env.showOnboarding = false
            }
            .frame(minWidth: 620, minHeight: 640)
            .environment(StoreKitService.shared)
            .environment(env)
        }
        .sheet(isPresented: $env.showPaywall) {
            PaywallScreen(
                onDone: { env.showPaywall = false },
                onSkip: { env.showPaywall = false }
            )
            .frame(minWidth: 560, minHeight: 680)
            .environment(StoreKitService.shared)
        }
        .alert("Keep your wallpaper running?", isPresented: $env.showAutostartPrompt) {
            Button("Add to Login Items") { LoginItemService.enable() }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Live and shader wallpapers only play while WallPics is running. Add it to Login Items so it starts automatically and your wallpaper keeps going after a restart — otherwise the desktop falls back to a still image.")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch env.selectedSection {
        case .browse:
            BrowseView(model: browseModel)
        case .favorites:
            FavoritesView(model: favoritesModel)
                .padding(.top, 54) // clear the floating nav (Browse's hero runs beneath it instead)
        case .uploads:
            UploadsView(model: browseModel)
                .padding(.top, 54)
        case .widgets:
            WidgetsView(model: widgetsModel)
                .padding(.top, 54)
        case .settings:
            SettingsView()
                .padding(.top, 54)
        }
    }
}

/// One4Wall-style chrome: brand mark left, a centered pill nav for the main sections, and
/// quick actions (Go Pro, settings gear) on the right — replaces the old sidebar.
private struct TopNavBar: View {
    @Binding var selection: AppEnvironment.Section
    @Binding var query: String
    @Environment(StoreKitService.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    AppIconView(size: 24)
                    Text(verbatim: "WallPics")
                        .font(.system(size: 14, weight: .bold))
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 5)
                .liquidGlass(in: Capsule())

                HStack(spacing: 2) {
                    navPill(.browse)
                    navPill(.uploads)
                    navPill(.widgets)
                    navPill(.favorites)
                }
                .padding(3)
                .liquidGlass(in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search wallpapers", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .frame(minWidth: 150, maxWidth: 340)
            .liquidGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            .animation(Motion.hover, value: searchFocused)

            HStack(spacing: Theme.Space.s) {
                if !store.state.isPro {
                    Button {
                        PaywallPresenter.show()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "crown.fill").font(.system(size: 10, weight: .bold))
                            Text("Go Pro").font(.callout.weight(.semibold))
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(Theme.accent.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    selection = .settings
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == .settings ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 30, height: 30)
                        .background {
                            if selection == .settings {
                                Circle().fill(Theme.accent)
                            }
                        }
                        .liquidGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Settings"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 9)
        // No bar background — the pills float over the hero, One4Wall style; each cluster
        // carries its own glass so it stays legible on any artwork.
        .animation(Motion.hover, value: selection)
    }

    private func navPill(_ section: AppEnvironment.Section) -> some View {
        let active = selection == section
        return Button {
            selection = section
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: section.symbol)
                    Text(section.label).lineLimit(1).fixedSize()
                }
                Image(systemName: section.symbol)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 6)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background {
                if active {
                    Capsule().fill(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(section.label)
    }
}
