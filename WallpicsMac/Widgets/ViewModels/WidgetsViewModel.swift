import SwiftUI
import Observation

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

    private(set) var categories: [WidgetCategoryNode] = []
    var selectedCategorySlug: String? = nil

    private(set) var items: [WidgetCatalogItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var page = 1
    private(set) var hasMore = true

    private var generation = 0
    private var didHeal = false
    private let api = WallpaperAPI.shared

    var store: WidgetStore { WidgetStore.shared }

    var myWidgets: [WidgetInstance] {
        let all = store.instances
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.kind.displayName.lowercased().contains(q) }
    }

    var filteredItems: [WidgetCatalogItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        let q = query.lowercased()
        return items.filter { ($0.name ?? "").lowercased().contains(q) }
    }

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

    func loadIfNeeded() async {
        if categories.isEmpty && items.isEmpty && !isLoading {
            await loadCategories()
            await reload()
        }
        await healStaleTemplates()
        // Keep the native-picker gallery fresh whenever the user opens Widgets.
        Task { await WidgetSharedExport.refreshCatalog() }
    }

    func healStaleTemplates() async {
        guard !didHeal else { return }
        didHeal = true
        let stale = store.instances.filter { instance in
            guard case .template(let t) = instance.payload else { return false }
            return t.thumbnailURLString == nil && t.previewRelativePath == nil
                && !instance.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        for instance in stale {
            do {
                let results = try await api.widgets(query: instance.name, perPage: 12)
                guard let match = results.first(where: {
                    ($0.name ?? "").compare(instance.name, options: .caseInsensitive) == .orderedSame
                }), let thumb = match.thumbnail, !thumb.isEmpty else { continue }
                store.updateTemplateAssets(id: instance.id, thumbnailURLString: thumb, templateSlug: match.typeKey)
            } catch {
                Log.api.debug("Widget thumbnail heal failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func loadCategories() async {
        do {
            categories = try await api.widgetCategories()
        } catch {
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

    func loadMore() async {
        guard hasMore, !isLoading, !items.isEmpty else { return }
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
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            hasMore = false
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
