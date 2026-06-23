import Foundation

enum WidgetPaths {
    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("WallpicsMac", isDirectory: true)
            .appendingPathComponent("Widgets", isDirectory: true)
        ensure(dir)
        return dir
    }

    static var instancesFile: URL { root.appendingPathComponent("instances.json") }
    static var placementsFile: URL { root.appendingPathComponent("placements.json") }

    static var instancesRoot: URL {
        let dir = root.appendingPathComponent("Instances", isDirectory: true)
        ensure(dir)
        return dir
    }

    static var templatesRoot: URL {
        let dir = root.appendingPathComponent("Templates", isDirectory: true)
        ensure(dir)
        return dir
    }

    static func assetsDirectory(for id: UUID) -> URL {
        let dir = instancesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        ensure(dir)
        return dir
    }

    static func templateDirectory(slug: String) -> URL {
        templatesRoot.appendingPathComponent(sanitizedSlug(slug), isDirectory: true)
    }

    static func sanitizedSlug(_ slug: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = slug.lowercased().unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned))
        return result.isEmpty ? "unknown" : result
    }

    private static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
