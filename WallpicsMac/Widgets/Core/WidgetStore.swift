import AppKit
import AVFoundation
import Observation
import SwiftUI

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
            instances = try decoder.decode([FailableInstance].self, from: data)
                .compactMap(\.value)
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
        renderAndSync(next)
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
        renderAndSync(instances[idx])
    }

    func delete(id: UUID) {
        instances.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: WidgetPaths.assetsDirectory(for: id))
        persist()
        WidgetSharedExport.sync()
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
    func importFile(from sourceURL: URL, into id: UUID) -> String? {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let fileName = "video_\(UUID().uuidString.prefix(8)).\(ext)"
        let dir = WidgetPaths.assetsDirectory(for: id)
        let dest = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return fileName
        } catch {
            Log.app.error("Widget video import failed: \(error.localizedDescription, privacy: .public)")
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

    private func renderAndSync(_ instance: WidgetInstance) {
        renderPrimaryImage(for: instance)
        WidgetSharedExport.sync()
    }

    private func renderPrimaryImage(for instance: WidgetInstance) {
        let size = instance.family.desktopSize
        switch instance.kind {
        case .elevator, .openedEyes, .garageDoor, .windowsXP:
            let view = WidgetRenderView(instance: instance,
                                        isToggled: Self.stillFlag(for: instance),
                                        carouselStep: 0)
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage {
                writeImage(image, named: WidgetSharedConfig.renderFileName, into: instance.id, asPNG: true)
            } else {
                removeRenderImage(for: instance.id)
            }
        case .video:
            guard case .video(let s) = instance.payload, !s.relativePath.isEmpty else {
                removeRenderImage(for: instance.id)
                return
            }
            let id = instance.id
            let url = assetURL(for: s.relativePath, in: id)
            Task { [weak self] in
                guard let self else { return }
                if let poster = await Self.makeVideoPoster(url: url, size: size) {
                    self.writeImage(poster, named: WidgetSharedConfig.renderFileName, into: id, asPNG: true)
                } else {
                    self.removeRenderImage(for: id)
                }
                WidgetSharedExport.sync()
            }
        case .photo, .staticImage, .polaroid, .diyAnimated, .template, .dateTime:
            removeRenderImage(for: instance.id)
        }
    }

    private func removeRenderImage(for id: UUID) {
        try? FileManager.default.removeItem(
            at: WidgetPaths.assetsDirectory(for: id).appendingPathComponent(WidgetSharedConfig.renderFileName))
    }

    nonisolated private static func makeVideoPoster(url: URL, size: CGSize) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: result.image, size: size)
    }

    private static func stillFlag(for instance: WidgetInstance) -> Bool {
        switch instance.payload {
        case .themed(let s): return s.isClosed
        case .diyAnimated(let s): return s.isOpen
        default: return false
        }
    }
}

private struct FailableInstance: Decodable {
    let value: WidgetInstance?
    init(from decoder: Decoder) throws {
        value = try? WidgetInstance(from: decoder)
    }
}
