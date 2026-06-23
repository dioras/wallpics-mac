import AppKit
import Observation

@MainActor
@Observable
final class WidgetStore {
    static let shared = WidgetStore()

    private(set) var instances: [WidgetInstance] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        load()
    }

    private func load() {
        let url = WidgetPaths.instancesFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            instances = try decoder.decode([WidgetInstance].self, from: data)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            Log.app.error("Widget instances load failed; backing up corrupt file: \(error.localizedDescription, privacy: .public)")
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(instances)
            try data.write(to: WidgetPaths.instancesFile, options: .atomic)
        } catch {
            Log.app.error("Widget instances save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func upsert(_ instance: WidgetInstance) {
        var next = instance
        next.updatedAt = Date()
        if let idx = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[idx] = next
        } else {
            instances.insert(next, at: 0)
        }
        instances.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func instance(id: UUID) -> WidgetInstance? {
        instances.first { $0.id == id }
    }

    func setToggle(id: UUID, isOn: Bool) {
        guard let idx = instances.firstIndex(where: { $0.id == id }) else { return }
        switch instances[idx].payload {
        case .themed(var s):
            s.isClosed = isOn
            instances[idx].payload = .themed(s)
        case .diyAnimated(var s):
            s.isOpen = isOn
            instances[idx].payload = .diyAnimated(s)
        default:
            return
        }
        persist()
    }

    func updateTemplateAssets(id: UUID, thumbnailURLString: String?, templateSlug: String?) {
        guard let idx = instances.firstIndex(where: { $0.id == id }),
              case .template(var t) = instances[idx].payload else { return }
        if let thumbnailURLString, !thumbnailURLString.isEmpty { t.thumbnailURLString = thumbnailURLString }
        if let templateSlug, !templateSlug.isEmpty, t.templateSlug.isEmpty { t.templateSlug = templateSlug }
        instances[idx].payload = .template(t)
        persist()
    }

    func delete(id: UUID) {
        instances.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: WidgetPaths.assetsDirectory(for: id))
        persist()
    }

    @discardableResult
    func importImage(from sourceURL: URL, into id: UUID, maxPixelSize: Int = 1024) -> String? {
        guard let image = WidgetImage.load(at: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        let keepAlpha = sourceURL.pathExtension.lowercased() == "png"
        guard let data = keepAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.92) else {
            return nil
        }
        let fileName = "photo_\(UUID().uuidString.prefix(8)).\(keepAlpha ? "png" : "jpg")"
        let dest = WidgetPaths.assetsDirectory(for: id).appendingPathComponent(fileName)
        do {
            try data.write(to: dest, options: .atomic)
            return fileName
        } catch {
            Log.app.error("Widget image import failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func writeImage(_ image: NSImage, named fileName: String, into id: UUID, asPNG: Bool = false) -> String? {
        guard let data = asPNG ? image.pngData() : image.jpegData(compressionQuality: 0.92) else { return nil }
        let dest = WidgetPaths.assetsDirectory(for: id).appendingPathComponent(fileName)
        do {
            try data.write(to: dest, options: .atomic)
            return fileName
        } catch {
            Log.app.error("Widget image write failed [\(fileName, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func assetURL(for relativePath: String, in id: UUID) -> URL {
        WidgetPaths.assetsDirectory(for: id).appendingPathComponent(relativePath)
    }
}
