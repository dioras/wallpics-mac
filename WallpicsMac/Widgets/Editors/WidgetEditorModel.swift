import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class WidgetEditorModel: Identifiable {
    nonisolated var id: UUID { instanceID }
    private let instanceID: UUID

    var instance: WidgetInstance
    let source: WidgetCatalogItem?

    private(set) var isPreparing = false
    private(set) var prepareError: String?
    var previewToggle = false
    var previewStep = 0

    private let isNew: Bool

    init(editing instance: WidgetInstance) {
        self.instance = instance
        self.instanceID = instance.id
        self.source = nil
        self.isNew = false
        self.previewToggle = Self.initialToggle(for: instance)
    }

    init(creating kind: WidgetKind, family: WidgetFamily? = nil, source: WidgetCatalogItem? = nil) {
        let fam = family ?? kind.supportedFamilies.first ?? .small
        var payload = Self.emptyPayload(for: kind)
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
        case .video(let s): return !s.relativePath.isEmpty
        case .staticImage(let s): return !s.relativePath.isEmpty
        case .polaroid(let s): return !s.relativePaths.isEmpty
        case .themed(let s): return s.photoRelativePath != nil
        case .diyAnimated(let s): return s.photoRelativePath != nil || s.coverRelativePath != nil
        case .template: return true
        }
    }

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
                if case .template(var s) = instance.payload { s.templateSlug = slug; instance.payload = .template(s) }
                seedTemplatePreview(slug: slug)
            }
            if instance.kind.themeSlug != nil, !WidgetAssetResolver.isInstalled(slug: slug) {
                prepareError = String(localized: "This widget's assets couldn't be downloaded. Check your connection and try again.")
            }
        } catch {
            prepareError = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Could not download this widget's assets.")
        }
    }

    private func importBundledStaticImage(slug: String) {
        let candidates = ["photo", "frame1", "image", "static"]
        var found: URL?
        for name in candidates {
            if let url = WidgetAssetResolver.url(forResource: name, withExtension: "png", slug: slug) {
                found = url; break
            }
        }
        guard let found, let rel = WidgetStore.shared.importImage(from: found, into: instance.id, maxPixelSize: 1200) else {
            prepareError = String(localized: "This widget's image couldn't be found in the downloaded bundle.")
            return
        }
        instance.payload = .staticImage(StaticImageState(relativePath: rel, sourceSlug: slug))
    }

    private func seedTemplatePreview(slug: String) {
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

    func addVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie, .video]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let rel = WidgetStore.shared.importFile(from: url, into: instance.id) else { return }
        append(relativePath: rel)
    }

    @discardableResult
    func importDropped(url: URL) -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        if instance.kind == .video {
            guard let rel = WidgetStore.shared.importFile(from: url, into: instance.id) else { return false }
            append(relativePath: rel)
        } else {
            guard let rel = WidgetStore.shared.importImage(from: url, into: instance.id) else { return false }
            append(relativePath: rel)
        }
        return true
    }

    func setFocalOffset(x: CGFloat, y: CGFloat) {
        let cx = max(-1, min(1, x)), cy = max(-1, min(1, y))
        switch instance.payload {
        case .photo(var s): s.offsetX = cx; s.offsetY = cy; instance.payload = .photo(s)
        case .video(var s): s.offsetX = cx; s.offsetY = cy; instance.payload = .video(s)
        default: break
        }
    }

    var videoAssetURL: URL? {
        guard let rel = instance.payload.videoPath else { return nil }
        return WidgetStore.shared.assetURL(for: rel, in: instance.id)
    }

    private func append(relativePath rel: String) {
        switch instance.payload {
        case .photo(var s):
            s.relativePaths.append(rel); instance.payload = .photo(s)
        case .video(var s):
            s.relativePath = rel; instance.payload = .video(s)
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
        switch instance.payload {
        case .photo(var s): s.fill = fill; instance.payload = .photo(s)
        case .video(var s): s.fill = fill; instance.payload = .video(s)
        default: break
        }
    }

    func setPolaroidBackground(_ bg: PolaroidWidgetState.Background) {
        if case .polaroid(var s) = instance.payload { s.background = bg; instance.payload = .polaroid(s) }
    }

    func setFamily(_ family: WidgetFamily) { instance.family = family }

    @discardableResult
    func save() -> WidgetInstance {
        if instance.kind == .diyAnimated { bakeDIYFrames() }
        WidgetStore.shared.upsert(instance)
        if let id = source?.id { Task { await WallpaperAPI.shared.recordWidgetUse(widgetID: id) } }
        return instance
    }

    private func bakeDIYFrames() {
        guard case .diyAnimated(var s) = instance.payload else { return }
        let slug = source?.typeKey ?? (s.templateSlug.isEmpty ? nil : s.templateSlug)
        guard let slug, !slug.isEmpty else { return }
        let photo = s.photoRelativePath.flatMap {
            WidgetImage.load(at: WidgetStore.shared.assetURL(for: $0, in: instance.id), maxPixelSize: 1024)
        }
        let baked = DIYFrameBaker.bake(slug: slug, family: instance.family, userPhoto: photo, into: instance.id)
        guard !baked.frames.isEmpty else { return }
        s.templateSlug = slug
        s.bakedFrameRelativePaths = baked.frames
        if let cover = baked.cover { s.coverRelativePath = cover }
        instance.payload = .diyAnimated(s)
    }

    private static func emptyPayload(for kind: WidgetKind) -> WidgetPayload {
        switch kind {
        case .photo: return .photo(PhotoWidgetState())
        case .video: return .video(VideoWidgetState())
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
