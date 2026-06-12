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

    // Two-level category filter, curated at runtime: only categories that actually return
    // content for the current collection are shown (probed concurrently, cached per session).
    var categories: [WallpaperCategory] = []
    var availableSubcategories: [WallpaperCategory] = []
    var selectedCategory: WallpaperCategory?
    var selectedSubcategory: WallpaperCategory?
    private var allCategories: [WallpaperCategory] = []
    private var curatedCache: [WallpaperCollection: [WallpaperCategory]] = [:]
    private var curatedSubsCache: [String: [WallpaperCategory]] = [:]

    // One4Wall-style editorial rail (community favorites, sorted by popularity).
    var popularRail: [Wallpaper] = []
    private var popularRailCache: [WallpaperCollection: [Wallpaper]] = [:]

    func loadPopularRailIfNeeded() async {
        let col = collection
        if let cached = popularRailCache[col] {
            if collection == col { popularRail = cached }
            return
        }
        // The backend's sortOrder is only asc/desc, so "popular" must be ranked client-side:
        // pull a wide newest page, rank by downloads/hot-rank, and exclude the first 14 items
        // (they're already on screen in the hero carousel) so the rail never repeats it.
        guard let page = try? await WallpaperAPI.shared.desktopWallpapers(
            collection: col, page: 1, perPage: 48, sortOrder: .newest
        ) else { return }
        let carouselIDs = Set(page.data.prefix(14).map(\.id))
        let ranked = page.data
            .filter { !carouselIDs.contains($0.id) }
            .sorted {
                ($0.safeDownloadCount, $0.hotRank ?? 0) > ($1.safeDownloadCount, $1.hotRank ?? 0)
            }
            .prefix(10)
        popularRailCache[col] = Array(ranked)
        if collection == col { popularRail = Array(ranked) }
    }
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
        query = ""
        selectedCategory = nil
        selectedSubcategory = nil
        availableSubcategories = []
        categories = curatedCache[newValue] ?? []
        popularRail = popularRailCache[newValue] ?? []
        Task { await reload() }
        Task { await curateCategories() }
        Task { await loadPopularRailIfNeeded() }
    }

    // MARK: - Categories

    func loadCategoriesIfNeeded() async {
        if allCategories.isEmpty {
            do {
                allCategories = try await WallpaperAPI.shared.categoryList()
            } catch {
                Log.api.error("Category list failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await curateCategories()
    }

    private func curateCategories() async {
        let col = collection
        if let cached = curatedCache[col] {
            if collection == col { categories = cached }
            return
        }
        // Fast path: the backend reports per-category content counts in one request
        // (hide count == 0, nil = show). Falls back to per-category probing on backends
        // that don't support counts yet.
        if let counted = try? await WallpaperAPI.shared.categoryList(countType: col.apiType),
           counted.contains(where: { $0.wallpapersCount != nil }) {
            let curated = counted
                .filter { $0.wallpapersCount != 0 }
                .map { parent in
                    WallpaperCategory(
                        id: parent.id, name: parent.name, slug: parent.slug,
                        children: parent.children.filter { $0.wallpapersCount != 0 },
                        wallpapersCount: parent.wallpapersCount
                    )
                }
            curatedCache[col] = curated
            if collection == col { categories = curated }
            return
        }
        guard !allCategories.isEmpty else { return }
        let curated = await Self.nonEmpty(allCategories, in: col)
        curatedCache[col] = curated
        if collection == col { categories = curated }
    }

    private func curateSubcategories(of parent: WallpaperCategory) async {
        let col = collection
        let key = "\(col.rawValue)|\(parent.slug)"
        if let cached = curatedSubsCache[key] {
            if selectedCategory?.id == parent.id { availableSubcategories = cached }
            return
        }
        // Count-curated parents already carry pre-filtered children.
        if parent.children.contains(where: { $0.wallpapersCount != nil }) || parent.wallpapersCount != nil {
            curatedSubsCache[key] = parent.children
            if selectedCategory?.id == parent.id { availableSubcategories = parent.children }
            return
        }
        let curated = await Self.nonEmpty(parent.children, in: col)
        curatedSubsCache[key] = curated
        if selectedCategory?.id == parent.id, collection == col {
            availableSubcategories = curated
        }
    }

    private nonisolated static func nonEmpty(
        _ candidates: [WallpaperCategory], in collection: WallpaperCollection
    ) async -> [WallpaperCategory] {
        guard !candidates.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, category) in candidates.enumerated() {
                group.addTask {
                    let page = try? await WallpaperAPI.shared.desktopWallpapers(
                        collection: collection, page: 1, perPage: 1, categorySlug: category.slug
                    )
                    return (index, page?.data.isEmpty == false)
                }
            }
            var keep = Set<Int>()
            for await (index, hasContent) in group where hasContent { keep.insert(index) }
            return candidates.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }
    }

    func selectCategory(_ category: WallpaperCategory?) {
        guard category?.id != selectedCategory?.id else { return }
        selectedCategory = category
        selectedSubcategory = nil
        availableSubcategories = []
        Task { await reload() }
        if let category, !category.children.isEmpty {
            Task { await curateSubcategories(of: category) }
        }
    }

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
