import Foundation
import WidgetKit

enum WidgetSharedExport {
    static let appGroupID = "group.com.kyragames.AestheticSadWallpapers"

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
        let destInstancesFile = widgetsRoot.appendingPathComponent("instances.json")

        do {
            try fileManager.createDirectory(at: widgetsRoot, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: instancesRoot)
            try fileManager.createDirectory(at: instancesRoot, withIntermediateDirectories: true)

            let sourceInstancesFile = WidgetPaths.instancesFile
            guard fileManager.fileExists(atPath: sourceInstancesFile.path) else {
                try? fileManager.removeItem(at: destInstancesFile)
                WidgetCenter.shared.reloadAllTimelines()
                return
            }

            let data = try Data(contentsOf: sourceInstancesFile)
            try data.write(to: destInstancesFile, options: .atomic)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let instances = try decoder.decode([WidgetInstance].self, from: data)

            for instance in instances {
                guard let relativePath = primaryRelativePath(instance), !relativePath.isEmpty else { continue }
                let source = WidgetPaths.assetsDirectory(for: instance.id).appendingPathComponent(relativePath)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destDir = instancesRoot.appendingPathComponent(instance.id.uuidString, isDirectory: true)
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                let dest = destDir.appendingPathComponent(relativePath)
                try? fileManager.removeItem(at: dest)
                try fileManager.copyItem(at: source, to: dest)
            }
        } catch {
            Log.app.error("WidgetSharedExport sync failed: \(error.localizedDescription, privacy: .public)")
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func primaryRelativePath(_ instance: WidgetInstance) -> String? {
        switch instance.payload {
        case .photo(let s):
            return s.relativePaths.first
        case .video:
            return nil
        case .staticImage(let s):
            return s.relativePath.isEmpty ? nil : s.relativePath
        case .template(let s):
            return s.previewRelativePath
        case .polaroid(let s):
            return s.relativePaths.first
        case .themed(let s):
            return s.photoRelativePath
        case .diyAnimated(let s):
            return s.coverRelativePath ?? s.bakedFrameRelativePaths.first ?? s.photoRelativePath
        }
    }
}
