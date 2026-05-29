import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var browseModel = BrowseViewModel()
    @State private var favoritesModel = FavoritesViewModel()

    var body: some View {
        @Bindable var env = env
        NavigationSplitView {
            SidebarView(selection: $env.selectedSection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            HStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if env.selectedWallpaper != nil {
                    Divider()
                    PreviewPanel()
                        .frame(width: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .environment(favoritesModel) // shared so the preview's star updates the grid live
            .animation(.easeInOut(duration: 0.25), value: env.selectedWallpaper?.id)
        }
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
    }

    @ViewBuilder
    private var detailContent: some View {
        switch env.selectedSection {
        case .browse: BrowseView(model: browseModel)
        case .favorites: FavoritesView(model: favoritesModel)
        case .settings: SettingsView()
        }
    }
}
