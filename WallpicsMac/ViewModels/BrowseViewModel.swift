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
    /// Live is the default collection — it's the product's hero content.
    var collection: WallpaperCollection = .live

    // Two-level category filter (roots + subcategories from api/category-list).
    var categories: [WallpaperCategory] = []
    var selectedCategory: WallpaperCategory?
    var selectedSubcategory: WallpaperCategory?
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
                sortOrder: sortOrder,
                categorySlug: (selectedSubcategory ?? selectedCategory)?.slug
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
        query = ""               // a search from the previous collection no longer applies
        selectedCategory = nil   // …and neither does a category filter
        selectedSubcategory = nil
        Task { await reload() }
    }

    // MARK: - Categories

    func loadCategoriesIfNeeded() async {
        guard categories.isEmpty else { return }
        do {
            categories = try await WallpaperAPI.shared.categoryList()
        } catch {
            // Non-fatal: the grid still works without filter chips; they appear on next visit.
            Log.api.error("Category list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Select a root category (nil = All). Resets any subcategory choice.
    func selectCategory(_ category: WallpaperCategory?) {
        guard category?.id != selectedCategory?.id else { return }
        selectedCategory = category
        selectedSubcategory = nil
        Task { await reload() }
    }

    /// Select a subcategory within the current root (nil = the whole root).
    func selectSubcategory(_ sub: WallpaperCategory?) {
        guard sub?.id != selectedSubcategory?.id else { return }
        selectedSubcategory = sub
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
