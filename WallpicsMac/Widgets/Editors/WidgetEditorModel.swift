import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Backs the widget editor: holds the in-progress `WidgetInstance`, imports photos via
/// `NSOpenPanel`, downloads any backend bundle the chosen widget needs, and saves to
/// `WidgetStore`. One adaptive model serves every kind — the editor view shows the relevant
/// controls per `instance.kind`.
@MainActor
@Observable
final class WidgetEditorModel: Identifiable {
    nonisolated var id: UUID { instanceID }
    private let instanceID: UUID

    var instance: WidgetInstance
    /// Catalog item this draft came from (for bundle download + usage reporting), if any.
    let source: WidgetCatalogItem?

    private(set) var isPreparing = false
    private(set) var prepareError: String?
    /// Drives the interactive preview tap (closed/hidden/animating).
    var previewToggle = false
    /// Drives the polaroid carousel preview (advances on tap).
    var previewStep = 0

    private let isNew: Bool

    /// Edit an existing instance.
    init(editing instance: WidgetInstance) {
        self.instance = instance
        self.instanceID = instance.id
        self.source = nil
        self.isNew = false
        self.previewToggle = Self.initialToggle(for: instance)
    }

    /// Create a new instance, optionally seeded from a catalog item.
    init(creating kind: WidgetKind, family: WidgetFamily? = nil, source: WidgetCatalogItem? = nil) {
        let fam = family ?? kind.supportedFamilies.first ?? .small
        var payload = Self.emptyPayload(for: kind)
        // Seed the catalog thumbnail so template / unsupported kinds have real artwork to render
        // even before (or without) a usable local preview asset.
        if case .template(var t) = payload {
            t.thumbnailURLString = source?.thumbnail
            payload = .template(t)
        }
        let name = source?.name ?? kind.displayName
        let inst = WidgetInstance(kind: kind, family: fam, name: name, payload: payload)
        self.instance = inst
        self.instanceID = inst.id
        self.source = source
        self.isNew = true
        self.previewToggle = false
    }

    var title: String { isNew ? String(localized: "New \(instance.kind.displayName) Widget") : String(localized: "Edit Widget") }

    var canSave: Bool {
        switch instance.payload {
        case .photo(let s): return !s.relativePaths.isEmpty
        case .staticImage(let s): return !s.relativePath.isEmpty
        case .polaroid(let s): return !s.relativePaths.isEmpty
        case .themed(let s): return s.photoRelativePath != nil
        case .diyAnimated(let s): return s.photoRelativePath != nil || s.coverRelativePath != nil
        case .template: return true
        }
    }

    // MARK: - Bundle / asset preparation

    /// Download the widget's backend bundle (themed / template / static assets) and, for static
    /// images, copy the bundled PNG into the instance directory. Safe to call on `.task`.
    func prepare() async {
        guard let source else { return }
        let slug = source.typeKey ?? instance.kind.themeSlug ?? (source.slug ?? "")
        guard !slug.isEmpty else { return }
        isPreparing = true
        prepareError = nil
        defer { isPreparing = false }
        do {
            try await WidgetBundleStore.shared.ensureInstalled(slug: slug, bundleURL: source.bundleDownloadURL)
            if instance.kind == .staticImage {
                importBundledStaticImage(slug: slug)
            }
            if instance.kind == .template {
                seedTemplatePreview(slug: slug)
            }
        } catch {
            prepareError = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Could not download this widget's assets.")
        }
    }

    private func importBundledStaticImage(slug: String) {
        // Static widgets ship a single image (`photo.png` or the first image in the bundle).
        let candidates = ["photo", "frame1", "image", "static"]
        var found: URL?
        for name in candidates {
            if let url = WidgetAssetResolver.url(forResource: name, withExtension: "png", slug: slug) {
                found = url; break
            }
        }
        guard let found, let rel = WidgetStore.shared.importImage(from: found, into: instance.id, maxPixelSize: 1200) else {
            // Surface this — otherwise Save stays disabled (empty relativePath) with no explanation.
            prepareError = String(localized: "This widget's image couldn't be found in the downloaded bundle.")
            return
        }
        instance.payload = .staticImage(StaticImageState(relativePath: rel, sourceSlug: slug))
    }

    private func seedTemplatePreview(slug: String) {
        // Use the bundle's animated/preview asset if present, else the catalog thumbnail will show.
        let candidates = [("preview", "webp"), ("preview", "png"), ("thumbnail", "png"), ("frame1", "png")]
        for (name, ext) in candidates {
            if let url = WidgetAssetResolver.url(forResource: name, withExtension: ext, slug: slug),
               let rel = WidgetStore.shared.importImage(from: url, into: instance.id, maxPixelSize: 1200) {
                if case .template(var s) = instance.payload {
                    s.previewRelativePath = rel
                    s.templateSlug = slug
                    instance.payload = .template(s)
                }
                return
            }
        }
    }

    // MARK: - Photo editing

    /// Present an open panel and import the chosen image(s) into the instance.
    func addPhotos(multiple: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let rel = WidgetStore.shared.importImage(from: url, into: instance.id) else { continue }
            append(relativePath: rel)
            if !multiple { break }
        }
    }

    private func append(relativePath rel: String) {
        switch instance.payload {
        case .photo(var s):
            s.relativePaths.append(rel); instance.payload = .photo(s)
        case .polaroid(var s):
            s.relativePaths.append(rel); instance.payload = .polaroid(s)
        case .themed(var s):
            s.photoRelativePath = rel; instance.payload = .themed(s)
        case .diyAnimated(var s):
            s.photoRelativePath = rel; s.coverRelativePath = rel; instance.payload = .diyAnimated(s)
        case .staticImage(var s):
            s.relativePath = rel; instance.payload = .staticImage(s)
        case .template(var s):
            s.photoRelativePath = rel; instance.payload = .template(s)
        }
    }

    func removePhoto(at index: Int) {
        switch instance.payload {
        case .photo(var s) where s.relativePaths.indices.contains(index):
            s.relativePaths.remove(at: index); instance.payload = .photo(s)
        case .polaroid(var s) where s.relativePaths.indices.contains(index):
            s.relativePaths.remove(at: index); instance.payload = .polaroid(s)
        default:
            break
        }
    }

    var photoRelativePaths: [String] {
        switch instance.payload {
        case .photo(let s): return s.relativePaths
        case .polaroid(let s): return s.relativePaths
        case .themed(let s): return s.photoRelativePath.map { [$0] } ?? []
        case .staticImage(let s): return s.relativePath.isEmpty ? [] : [s.relativePath]
        default: return []
        }
    }

    func setFill(_ fill: Bool) {
        if case .photo(var s) = instance.payload { s.fill = fill; instance.payload = .photo(s) }
    }

    func setPolaroidBackground(_ bg: PolaroidWidgetState.Background) {
        if case .polaroid(var s) = instance.payload { s.background = bg; instance.payload = .polaroid(s) }
    }

    func setFamily(_ family: WidgetFamily) { instance.family = family }

    // MARK: - Save

    @discardableResult
    func save() -> WidgetInstance {
        WidgetStore.shared.upsert(instance)
        if let id = source?.id { Task { await WallpaperAPI.shared.recordWidgetUse(widgetID: id) } }
        return instance
    }

    // MARK: - Defaults

    private static func emptyPayload(for kind: WidgetKind) -> WidgetPayload {
        switch kind {
        case .photo: return .photo(PhotoWidgetState())
        case .staticImage: return .staticImage(StaticImageState())
        case .polaroid: return .polaroid(PolaroidWidgetState())
        case .elevator, .openedEyes, .garageDoor, .windowsXP: return .themed(ThemedToggleState())
        case .diyAnimated: return .diyAnimated(DIYAnimatedWidgetState())
        case .template: return .template(TemplateWidgetState())
        }
    }

    private static func initialToggle(for instance: WidgetInstance) -> Bool {
        switch instance.payload {
        case .themed(let s): return s.isClosed
        case .diyAnimated(let s): return s.isOpen
        default: return false
        }
    }
}
