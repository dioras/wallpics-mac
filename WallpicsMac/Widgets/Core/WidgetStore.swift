import AppKit
import Observation

/// Owns the user's created widgets: load/save to `WidgetPaths.instancesFile`, import photos into
/// each instance's asset directory, and CRUD. Observed by the gallery so saving a widget updates
/// the UI immediately. Mirrors the role of the iOS App Group state stores, but app-local.
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

    // MARK: - Load / save

    private func load() {
        let url = WidgetPaths.instancesFile
        // A missing file is the normal first-launch case; only an existing-but-unreadable file is
        // an error worth logging (so a corrupt/locked store doesn't masquerade as "no widgets").
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            instances = try decoder.decode([WidgetInstance].self, from: data)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            Log.app.error("Widget instances load failed: \(error.localizedDescription, privacy: .public)")
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

    // MARK: - CRUD

    /// Insert or update an instance (matched by id) and persist. Newest-updated first.
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

    /// Toggle the interactive flag (elevator/garage/etc. open-closed, DIY open) and persist.
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

    func delete(id: UUID) {
        instances.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: WidgetPaths.assetsDirectory(for: id))
        persist()
    }

    // MARK: - Asset import

    /// Copy a picked image into the instance's asset directory, downsampled to a sane max, and
    /// return its file name (relative path). Returns `nil` if the file can't be read or encoded.
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

    /// Persist an in-memory NSImage (e.g. a baked frame) into the instance directory.
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

    /// Absolute URL for a relative asset path stored in an instance payload.
    func assetURL(for relativePath: String, in id: UUID) -> URL {
        WidgetPaths.assetsDirectory(for: id).appendingPathComponent(relativePath)
    }
}
