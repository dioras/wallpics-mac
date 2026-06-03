import Foundation
import Observation

@MainActor
@Observable
final class BrowseViewModel {
    var wallpapers: [Wallpaper] = []
    var imported: [Wallpaper] = []          // user uploads, shown under "Your Uploads"
    var isImporting = false
    var query: String = ""
    var sortOrder: SortOrder = .newest
    var collection: WallpaperCollection = .normal
    var isLoading = false
    var errorMessage: String?
    var currentPage = 1
    var hasMore = true

    /// Bumped on every reload so a late-returning request from a previous sort/query is
    /// recognised as stale and its results are discarded instead of polluting the grid.
    private var generation = 0

    /// Client-side paging only makes sense over the full set; while the user is searching we
    /// match against already-loaded pages and must not keep fetching more.
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var filteredWallpapers: [Wallpaper] {
        guard isSearching else { return wallpapers }
        let needle = query.lowercased()
        return wallpapers.filter {
            $0.name.lowercased().contains(needle) ||
            $0.safeTags.contains { $0.name.lowercased().contains(needle) }
        }
    }

    /// Show the infinite-scroll loader only when there's genuinely more to fetch and we're
    /// not in a client-side search.
    var canLoadMore: Bool { hasMore && errorMessage == nil && !isSearching }

    func loadFirstPageIfNeeded() async {
        guard wallpapers.isEmpty else { return }
        await reload()
    }

    func reload() async {
        generation += 1
        let gen = generation
        currentPage = 1
        hasMore = true
        isLoading = false   // cancel any in-flight page's effect; its append is gated by gen
        wallpapers = []
        await loadPage(gen: gen)
    }

    /// `force` lets the search UI pull one more page on demand (bypassing the no-paging-while-
    /// searching rule) without enabling the auto-scroll loader that caused runaway paging.
    func loadNextPage(force: Bool = false) async {
        guard (force ? hasMore && errorMessage == nil : canLoadMore), !isLoading else { return }
        await loadPage(gen: generation)
    }

    private func loadPage(gen: Int) async {
        guard !isLoading else { return }
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await WallpaperAPI.shared.desktopWallpapers(
                collection: collection,
                page: currentPage,
                perPage: 24,
                sortOrder: sortOrder
            )
            guard gen == generation else { return } // a newer reload superseded this request
            wallpapers.append(contentsOf: page.data)
            hasMore = page.info.currentPage < page.info.lastPage
            currentPage = page.info.currentPage + 1
            errorMessage = nil
        } catch {
            guard gen == generation else { return }
            errorMessage = error.localizedDescription
            Log.api.error("Browse load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setSort(_ order: SortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        Task { await reload() }
    }

    func setCollection(_ newValue: WallpaperCollection) {
        guard newValue != collection else { return }
        collection = newValue
        query = ""   // a search from the previous collection no longer applies
        Task { await reload() }
    }

    // MARK: - Imports

    func loadImports() async {
        imported = await CacheManager.shared.importedWallpapers()
    }

    /// Open the file picker and import; returns the new wallpaper so the caller can preview it.
    func importWallpaper() async -> Wallpaper? {
        isImporting = true
        defer { isImporting = false }
        guard let wp = await ImportService.pickAndImport() else { return nil }
        await loadImports()
        return wp
    }

    func removeImport(_ wallpaper: Wallpaper) async {
        await CacheManager.shared.removeImport(wallpaper)
        await loadImports()
    }
}
