import Foundation
import WidgetKit

enum WidgetSharedExport {
    static let appGroupID = WidgetSharedConfig.appGroupID

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func sync() {
        guard let container = containerURL else {
            Log.app.error("WidgetSharedExport: App Group container unavailable for \(appGroupID, privacy: .public)")
            return
        }

        let fileManager = FileManager.default
        let widgetsRoot = container.appendingPathComponent("Widgets", isDirectory: true)
        let instancesRoot = widgetsRoot.appendingPathComponent("Instances", isDirectory: true)
        let staging = widgetsRoot.appendingPathComponent("Instances.staging", isDirectory: true)
        let destInstancesFile = widgetsRoot.appendingPathComponent("instances.json")

        do {
            try fileManager.createDirectory(at: widgetsRoot, withIntermediateDirectories: true)

            let sourceInstancesFile = WidgetPaths.instancesFile
            guard fileManager.fileExists(atPath: sourceInstancesFile.path) else {
                try? fileManager.removeItem(at: staging)
                try? fileManager.removeItem(at: instancesRoot)
                try? fileManager.removeItem(at: destInstancesFile)
                WidgetCenter.shared.reloadAllTimelines()
                return
            }

            let data = try Data(contentsOf: sourceInstancesFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let instances = try decoder.decode([WidgetInstance].self, from: data)

            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for instance in instances {
                guard let asset = sharedAsset(for: instance, fileManager: fileManager) else { continue }
                let destDir = staging.appendingPathComponent(instance.id.uuidString, isDirectory: true)
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                try fileManager.copyItem(at: asset.source, to: destDir.appendingPathComponent(asset.name))
            }

            if fileManager.fileExists(atPath: instancesRoot.path) {
                _ = try fileManager.replaceItemAt(instancesRoot, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: instancesRoot)
            }

            try data.write(to: destInstancesFile, options: .atomic)
        } catch {
            Log.app.error("WidgetSharedExport sync failed: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: staging)
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    private struct CatalogEntry: Encodable { let id: String; let name: String; let image: String }

    /// Fetch the ENTIRE backend widget gallery (paging through all of it) and publish it, so the
    /// native picker offers EVERY WallPics widget — not just ones the user created. New gallery
    /// widgets appear on the next refresh.
    static func refreshCatalog() async {
        // The whole gallery (125+), not the flat endpoint's 32 — see WallpaperAPI.allGalleryWidgets.
        let items = (try? await WallpaperAPI.shared.allGalleryWidgets()) ?? []
        guard !items.isEmpty else { return }
        await syncCatalog(items)
    }

    /// Download each gallery preview once into the App Group and write a manifest the extension
    /// reads. Cached images are skipped, stale ones pruned — safe to call on every launch.
    static func syncCatalog(_ items: [WidgetCatalogItem]) async {
        guard let container = containerURL else {
            Log.app.error("WidgetSharedExport.catalog: App Group container unavailable")
            return
        }
        let catalogRoot = container.appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
        let catalogFile = container.appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("catalog.json")
        try? FileManager.default.createDirectory(at: catalogRoot, withIntermediateDirectories: true)

        // Download any missing previews concurrently.
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                guard let rawID = item.id, !rawID.isEmpty, let thumb = item.thumbnailURL else { continue }
                let dest = catalogRoot.appendingPathComponent("catalog-\(rawID)", isDirectory: true)
                    .appendingPathComponent("image.jpg")
                if FileManager.default.fileExists(atPath: dest.path) { continue }
                group.addTask {
                    guard let (data, resp) = try? await URLSession.shared.data(from: thumb),
                          (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                          !data.isEmpty else { return }
                    try? FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: dest, options: .atomic)
                }
            }
        }

        // Build the manifest from items whose preview is now on disk, and prune the rest.
        var entries: [CatalogEntry] = []
        var keep = Set<String>()
        for item in items {
            guard let rawID = item.id, !rawID.isEmpty, let name = item.name, !name.isEmpty else { continue }
            let cid = "catalog-\(rawID)"
            let dest = catalogRoot.appendingPathComponent(cid, isDirectory: true).appendingPathComponent("image.jpg")
            guard FileManager.default.fileExists(atPath: dest.path) else { continue }
            keep.insert(cid)
            entries.append(CatalogEntry(id: cid, name: name, image: "image.jpg"))
        }
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: catalogRoot.path) {
            for dir in existing where !keep.contains(dir) {
                try? FileManager.default.removeItem(at: catalogRoot.appendingPathComponent(dir))
            }
        }
        if let json = try? JSONEncoder().encode(entries) {
            try? json.write(to: catalogFile, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func sharedAsset(for instance: WidgetInstance, fileManager: FileManager) -> (source: URL, name: String)? {
        if instance.kind == .dateTime { return nil }
        let dir = WidgetPaths.assetsDirectory(for: instance.id)
        let render = dir.appendingPathComponent(WidgetSharedConfig.renderFileName)
        if fileManager.fileExists(atPath: render.path) {
            return (render, WidgetSharedConfig.renderFileName)
        }
        guard let rel = instance.payload.sharedImageRelativePath(), !rel.isEmpty else {
            Log.app.error("WidgetSharedExport: no shared image for instance \(instance.id, privacy: .public)")
            return nil
        }
        let source = dir.appendingPathComponent(rel)
        guard fileManager.fileExists(atPath: source.path) else {
            Log.app.error("WidgetSharedExport: missing asset \(rel, privacy: .public) for \(instance.id, privacy: .public)")
            return nil
        }
        return (source, rel)
    }
}
