import Foundation

/// On-disk layout for the widget subsystem. Everything lives under the app's Application Support
/// directory (sandbox container), so no App Group / provisioning is required — the Mac app both
/// writes and renders widgets itself.
///
///     Application Support/WallpicsMac/Widgets/
///       ├─ instances.json            // [WidgetInstance]
///       ├─ placements.json           // [DesktopWidgetPlacement]
///       ├─ Instances/<uuid>/…        // per-instance photos, baked frames, copied images
///       └─ Templates/<slug>/…        // downloaded backend bundles (themed assets, configs)
enum WidgetPaths {
    /// `Application Support/WallpicsMac/Widgets`.
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

    /// Per-instance asset directory. Relative paths inside a `WidgetInstance` payload resolve here.
    static func assetsDirectory(for id: UUID) -> URL {
        let dir = instancesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        ensure(dir)
        return dir
    }

    /// Downloaded bundle directory for a template/theme slug. The slug is sanitised to a single
    /// safe path segment so a hostile backend value (e.g. `../instances`) can never escape the
    /// templates root and clobber sibling state files.
    static func templateDirectory(slug: String) -> URL {
        templatesRoot.appendingPathComponent(sanitizedSlug(slug), isDirectory: true)
    }

    /// Lowercase, keep only `[a-z0-9_-]`, and never allow an empty / dot-only result.
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
