import SwiftUI

struct FavoritesView: View {
    @Bindable var model: FavoritesViewModel
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: Theme.Space.l)]

    var body: some View {
        Group {
            if model.wallpapers.isEmpty {
                VStack {
                    ContentUnavailableView {
                        Label("No favorites yet", systemImage: "star")
                    } description: {
                        Text("Click the star on any wallpaper while browsing to save it here.")
                    } actions: {
                        Button("Open Browse") { env.selectedSection = .browse }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: 600)
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                        ForEach(model.wallpapers) { wallpaper in
                            WallpaperCard(wallpaper: wallpaper, isSelected: env.selectedWallpaper?.id == wallpaper.id)
                                .onTapGesture {
                                    withAnimation(Motion.transition) { env.detailWallpaper = wallpaper }
                                }
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                                    removal: .scale(scale: 0.85).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(Theme.Space.l)
                    .animation(Motion.reward, value: model.wallpapers.map(\.id))
                }
                .scrollContentBackground(.hidden)
            }
        }
        // Match every other tab: solid dark backdrop (the empty state used the light window
        // colour before). Forcing the dark scheme keeps the empty-state text legible on black.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .task { await model.refresh() }
    }
}
