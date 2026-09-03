import Foundation
import Observation

enum BrowseMode: Equatable {
    case home
    case collection
}

@MainActor
@Observable
final class BrowseViewModel {
    var mode: BrowseMode = .home
    var homeRails: [WallpaperCollection: [Wallpaper]] = [:]
    var homeRailsFailed = false
    var isLoadingHome = false
    private static let railLength = 14

    var wallpapers: [Wallpaper] = []
    var imported: [Wallpaper] = []          // user uploads, shown under "Your Uploads"
    var isImporting = false
    var query: String = ""
    var sortOrder: SortOrder = .newest
    /// Live is the default collection — it's the product's hero content.
    var collection: WallpaperCollection = .live

    // Two-level category filter. The backend's per-type category-list returns only categories that
    // actually have content for the current collection (5 photo / 6 live / 7 shader), with slugs
    // that match that collection — so we use it directly, cached per collection, no probing.
    var categories: [WallpaperCategory] = []
    var availableSubcategories: [WallpaperCategory] = []
    var selectedCategory: WallpaperCategory?
    var selectedSubcategory: WallpaperCategory?
    private var curatedCache: [WallpaperCollection: [WallpaperCategory]] = [:]

    // "Most Popular" rail — real backend popularity for the CURRENT collection + category filter,
    // so it reacts to the chips like the client asked (was a static, filter-blind client-side rank).
    var popularRail: [Wallpaper] = []

    func loadPopularRail() async {
        let col = collection
        let catSlug = (selectedSubcategory ?? selectedCategory)?.slug
        guard let page = try? await WallpaperAPI.shared.desktopWallpapers(
            collection: col, page: 1, perPage: 20, sortOrder: .popular, categorySlug: catSlug
        ) else { return }
        // Drop a stale response from a superseded collection/filter.
        guard collection == col,
              (selectedSubcategory ?? selectedCategory)?.slug == catSlug else { return }
        // The strip over the hero is the "Most Popular" rail — a scrollable set, but small enough
        // that excluding it from the grid below doesn't thin "All Wallpapers".
        popularRail = Array(page.data.prefix(14))
    }
    var isLoading = false
    var errorMessage: String?
    var currentPage = 1
    var hasMore = true

    /// Bumped on every reload so a late-returning request from a previous sort/query is
    /// recognised as stale and its results are discarded instead of polluting the grid.
    private var generation = 0

    /// Frozen once per reload so paging stays consistent; `seenIDs` rejects duplicate ids so the
    /// grid never holds two cards with the same Identifiable id (SwiftUI undefined behaviour — the
    /// "All Wallpapers" corruption/hang the client hit).
    private var pageTimestamp = 0
    private var seenIDs = Set<Wallpaper.ID>()

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
        seenIDs.removeAll()
        pageTimestamp = Int(Date().timeIntervalSince1970)
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
        // The infinite-scroll sentinel only re-fires when the grid grows, so a page whose ids are
        // all already-seen (dedup → zero fresh) would stall paging. Skip up to a few such pages in
        // one pass until we get fresh content or reach the end.
        for _ in 0..<5 {
            do {
                let page = try await WallpaperAPI.shared.desktopWallpapers(
                    collection: collection,
                    page: currentPage,
                    perPage: 24,
                    sortOrder: sortOrder,
                    categorySlug: (selectedSubcategory ?? selectedCategory)?.slug,
                    timestamp: pageTimestamp
                )
                guard gen == generation else { return } // a newer reload superseded this request
                let fresh = page.data.filter { seenIDs.insert($0.id).inserted }
                wallpapers.append(contentsOf: fresh)
                hasMore = page.info.currentPage < page.info.lastPage
                currentPage = page.info.currentPage + 1
                errorMessage = nil
                if !fresh.isEmpty || !hasMore { return }
            } catch {
                guard gen == generation else { return }
                errorMessage = error.localizedDescription
                Log.api.error("Browse load failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    func setSort(_ order: SortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        Task { await reload() }
    }

    func showHome() {
        guard mode != .home else { return }
        mode = .home
        query = ""
        Task { await loadHomeRailsIfNeeded() }
    }

    func loadHomeRailsIfNeeded() async {
        guard homeRails.count < WallpaperCollection.allCases.count, !isLoadingHome else { return }
        await loadHomeRails()
    }

    func loadHomeRails() async {
        guard !isLoadingHome else { return }
        isLoadingHome = true
        homeRailsFailed = false
        async let photos = Self.fetchRail(.normal)
        async let live = Self.fetchRail(.live)
        async let shaders = Self.fetchRail(.shader)
        let results = await [(WallpaperCollection.normal, photos), (.live, live), (.shader, shaders)]
        isLoadingHome = false
        guard !Task.isCancelled else { return }
        for (col, items) in results {
            if let items, !items.isEmpty { homeRails[col] = items }
        }
        homeRailsFailed = homeRails.isEmpty
        if homeRailsFailed {
            Log.api.error("Browse home rails failed to load")
        }
    }

    private nonisolated static func fetchRail(_ col: WallpaperCollection) async -> [Wallpaper]? {
        do {
            let page = try await WallpaperAPI.shared.desktopWallpapers(
                collection: col, page: 1, perPage: railLength, sortOrder: .popular
            )
            return page.data
        } catch {
            Log.api.error("Browse rail \(col.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func setCollection(_ newValue: WallpaperCollection) {
        let wasHome = mode == .home
        mode = .collection
        if newValue == collection {
            guard wasHome else { return }
            if wallpapers.isEmpty { Task { await reload() } }
            if popularRail.isEmpty { Task { await loadPopularRail() } }
            return
        }
        collection = newValue
        query = ""
        selectedCategory = nil
        selectedSubcategory = nil
        availableSubcategories = []
        categories = curatedCache[newValue] ?? []
        popularRail = []
        Task { await reload() }
        Task { await curateCategories() }
        Task { await loadPopularRail() }
    }

    // MARK: - Categories

    func loadCategoriesIfNeeded() async {
        await curateCategories()
    }

    private func curateCategories() async {
        let col = collection
        if let cached = curatedCache[col] {
            if collection == col { categories = cached }
            return
        }
        // The backend's per-type category list already returns only categories that HAVE content
        // for this exact collection (5 photo / 6 live / 7 shader), with slugs that match — so no
        // probing is needed and clicking a category actually returns wallpapers. Live/Shader
        // legitimately have few categories right now; that's backend tagging, not a bug to hide.
        guard let cats = try? await WallpaperAPI.shared.categoryList(type: col.apiType) else { return }
        curatedCache[col] = cats
        if collection == col { categories = cats }
    }

    func selectCategory(_ category: WallpaperCategory?) {
        guard category?.id != selectedCategory?.id else { return }
        selectedCategory = category
        selectedSubcategory = nil
        // Children arrive with the same per-type call, already scoped to this collection.
        availableSubcategories = category?.children ?? []
        popularRail = []
        Task { await reload() }
        Task { await loadPopularRail() }
    }

    func selectSubcategory(_ sub: WallpaperCategory?) {
        guard sub?.id != selectedSubcategory?.id else { return }
        selectedSubcategory = sub
        popularRail = []
        Task { await reload() }
        Task { await loadPopularRail() }
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
