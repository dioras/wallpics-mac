import Foundation
import ImageIO
import CoreGraphics
import SwiftUI
import os

struct SharedWidget: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable { case instance, catalog }
    let id: String
    let name: String
    let kindRawValue: String
    let imageRelativePath: String?
    var source: Source = .instance
    var dateTime: DateTimeWidgetState? = nil

    var displayName: String {
        name.isEmpty ? displayKind : name
    }

    var displayKind: String {
        WidgetKind(rawValue: kindRawValue)?.displayName ?? "Widget"
    }
}

struct WidgetSharedStore: Sendable {
    static let appGroupID = WidgetSharedConfig.appGroupID
    static let shared = WidgetSharedStore()
    private static let log = Logger(subsystem: "com.kyragames.AestheticSadWallppapers.WidgetExtension",
                                    category: "shared-store")

    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    var widgetsRoot: URL? {
        containerURL?.appendingPathComponent("Widgets", isDirectory: true)
    }

    var instancesFile: URL? {
        widgetsRoot?.appendingPathComponent("instances.json")
    }

    var instancesRoot: URL? {
        widgetsRoot?.appendingPathComponent("Instances", isDirectory: true)
    }

    var catalogFile: URL? {
        widgetsRoot?.appendingPathComponent("catalog.json")
    }

    var catalogRoot: URL? {
        widgetsRoot?.appendingPathComponent("Catalog", isDirectory: true)
    }

    /// The user's own created widgets first, then the full backend gallery — so the native picker
    /// offers every WallPics widget (and new ones appear automatically as the exported catalog grows).
    func allWidgets() -> [SharedWidget] {
        instanceWidgets() + catalogWidgets()
    }

    private struct CatalogEntry: Decodable { let id: String; let name: String; let image: String }

    private func catalogWidgets() -> [SharedWidget] {
        guard let url = catalogFile,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CatalogEntry].self, from: data) else {
            return []
        }
        return entries.map {
            SharedWidget(id: $0.id, name: $0.name, kindRawValue: "photo",
                         imageRelativePath: $0.image, source: .catalog)
        }
    }

    private func instanceWidgets() -> [SharedWidget] {
        guard let url = instancesFile else {
            Self.log.error("App Group container unavailable for \(Self.appGroupID, privacy: .public)")
            return []
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: [Failable<WidgetInstance>]
        do {
            decoded = try decoder.decode([Failable<WidgetInstance>].self, from: data)
        } catch {
            Self.log.error("instances.json decode failed: \(String(describing: error), privacy: .public)")
            return []
        }
        let instances = decoded.compactMap(\.value).sorted { $0.updatedAt > $1.updatedAt }
        if instances.count != decoded.count {
            Self.log.error("Dropped \(decoded.count - instances.count) undecodable widget instance(s)")
        }
        return instances.map { instance in
            SharedWidget(id: instance.id.uuidString,
                         name: instance.name,
                         kindRawValue: instance.kind.rawValue,
                         imageRelativePath: resolveImageRelativePath(for: instance),
                         dateTime: instance.payload.dateTimeState)
        }
    }

    func widget(id: String) -> SharedWidget? {
        allWidgets().first { $0.id == id }
    }

    private func resolveImageRelativePath(for instance: WidgetInstance) -> String? {
        if let root = instancesRoot {
            let render = root.appendingPathComponent(instance.id.uuidString, isDirectory: true)
                .appendingPathComponent(WidgetSharedConfig.renderFileName)
            if FileManager.default.fileExists(atPath: render.path) {
                return WidgetSharedConfig.renderFileName
            }
        }
        return instance.payload.sharedImageRelativePath()
    }

    func imageURL(for widget: SharedWidget) -> URL? {
        guard let relativePath = widget.imageRelativePath, !relativePath.isEmpty else { return nil }
        let root = widget.source == .catalog ? catalogRoot : instancesRoot
        guard let root else { return nil }
        let url = root
            .appendingPathComponent(widget.id, isDirectory: true)
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func cgImage(for widget: SharedWidget, maxPixelSize: Int = 1200) -> CGImage? {
        guard let url = imageURL(for: widget) else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    func image(for widget: SharedWidget, maxPixelSize: Int = 1200) -> Image? {
        guard let cg = cgImage(for: widget, maxPixelSize: maxPixelSize) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}

private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
