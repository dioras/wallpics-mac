import SwiftUI
import Observation

/// Drives the Widgets tab: loads the backend catalog (categories + paginated items) and surfaces
/// the user's created widgets from `WidgetStore`. Follows the same generation-gated async pattern
/// as `BrowseViewModel` so rapid category switches discard stale responses.
@MainActor
@Observable
final class WidgetsViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case gallery, mine
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gallery: return String(localized: "Gallery")
            case .mine: return String(localized: "My Widgets")
            }
        }
    }

    var tab: Tab = .gallery
    var query: String = ""

    /// Top-level + leaf categories flattened for the chip row. `nil` slug = "All".
    private(set) var categories: [WidgetCategoryNode] = []
    var selectedCategorySlug: String? = nil

    /// Catalog items for the current category selection.
    private(set) var items: [WidgetCatalogItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var page = 1
    private(set) var hasMore = true

    private var generation = 0
    private let api = WallpaperAPI.shared

    var store: WidgetStore { WidgetStore.shared }

    /// User-created widgets, filtered by the search query.
    var myWidgets: [WidgetInstance] {
        let all = store.instances
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.kind.displayName.lowercased().contains(q) }
    }

    /// Catalog items filtered by the search query (client-side, like the iOS gallery).
    var filteredItems: [WidgetCatalogItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        let q = query.lowercased()
        return items.filter { ($0.name ?? "").lowercased().contains(q) }
    }

    /// Leaf categories to show as chips (skip the two structural parents, like iOS).
    var categoryChips: [WidgetCategoryNode] {
        var leaves: [WidgetCategoryNode] = []
        func walk(_ nodes: [WidgetCategoryNode]) {
            for node in nodes {
                if let children = node.children, !children.isEmpty {
                    walk(children)
                } else {
                    leaves.append(node)
                }
            }
        }
        walk(categories)
        return leaves
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        if categories.isEmpty && items.isEmpty && !isLoading {
            await loadCategories()
            await reload()
        }
    }

    func loadCategories() async {
        do {
            categories = try await api.widgetCategories()
        } catch {
            // Non-fatal: the gallery still works as a flat list without category chips. Logged at
            // info so it's visible in release logs without a streaming profile.
            Log.api.info("Widget categories load failed (non-fatal): \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectCategory(_ slug: String?) {
        guard slug != selectedCategorySlug else { return }
        selectedCategorySlug = slug
        Task { await reload() }
    }

    func reload() async {
        generation += 1
        let gen = generation
        page = 1
        hasMore = true
        isLoading = true
        loadError = nil
        defer { if gen == generation { isLoading = false } }
        do {
            let fetched = try await api.widgets(categorySlug: selectedCategorySlug, page: 1)
            guard gen == generation else { return }
            items = dedupe(fetched)
            hasMore = !fetched.isEmpty
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            items = []
            loadError = (error as? LocalizedError)?.errorDescription ?? String(localized: "Could not load widgets.")
        }
    }

    func loadNextPageIfNeeded(currentItem: WidgetCatalogItem) async {
        guard hasMore, !isLoading, currentItem.id == items.last?.id else { return }
        let gen = generation
        let next = page + 1
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let fetched = try await api.widgets(categorySlug: selectedCategorySlug, page: next)
            guard gen == generation else { return }
            if fetched.isEmpty {
                hasMore = false
            } else {
                page = next
                items = dedupe(items + fetched)
            }
        } catch {
            // Leave the existing list intact on a paging error; the user can still scroll what
            // loaded. Logged for diagnostics.
            Log.api.debug("Widget pagination failed (non-fatal): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func dedupe(_ list: [WidgetCatalogItem]) -> [WidgetCatalogItem] {
        var seen = Set<String>()
        return list.filter { item in
            let key = item.id ?? item.slug ?? UUID().uuidString
            return seen.insert(key).inserted
        }
    }
}
