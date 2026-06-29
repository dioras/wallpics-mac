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
