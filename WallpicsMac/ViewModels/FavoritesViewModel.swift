import Foundation
import Observation

@MainActor
@Observable
final class FavoritesViewModel {
    var wallpapers: [Wallpaper] = []
    private var favoriteIDs: Set<Int> = []

    /// Load favorites straight from disk — independent of what Browse has paginated, so it's
    /// correct on first launch and after relaunch.
    func refresh() async {
        let favs = await CacheManager.shared.favoriteWallpapers()
        wallpapers = favs
        favoriteIDs = Set(favs.map(\.id))
    }

    func isFavorite(_ wallpaper: Wallpaper) -> Bool {
        favoriteIDs.contains(wallpaper.id)
    }

    func toggle(_ wallpaper: Wallpaper) async {
        let isNowFavorite = !favoriteIDs.contains(wallpaper.id)
        // Optimistic update so the star + grid react instantly, before the disk round-trip.
        if isNowFavorite {
            favoriteIDs.insert(wallpaper.id)
            if !wallpapers.contains(where: { $0.id == wallpaper.id }) {
                wallpapers.insert(wallpaper, at: 0)
            }
        } else {
            favoriteIDs.remove(wallpaper.id)
            wallpapers.removeAll { $0.id == wallpaper.id }
        }
        await CacheManager.shared.setFavorite(wallpaper, favorite: isNowFavorite)
        await refresh()
    }
}
