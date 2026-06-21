import Foundation

/// Resolves themed-widget assets (`frameN.png`, backdrops, etc.), ported from the iOS
/// `WidgetAssetResolver`. The iOS app looks in the App Group `WidgetTemplates/` tree first, then
/// falls back to the main bundle. Here the equivalent locations are the downloaded
/// `WidgetPaths.templatesRoot` tree first, then any assets shipped in the app bundle.
///
/// iOS lays themed assets out as `WidgetTemplates/<slug>/<family>/frameN.png`. We download bundles
/// flat into `Templates/<slug>/…`, so we probe a few plausible sub-paths to stay compatible with
/// either a nested (`<slug>/<family>/…`) or flat (`<slug>/…`) bundle layout.
enum WidgetAssetResolver {
    /// Returns the on-disk URL for a themed asset, or `nil` if it isn't installed yet.
    /// - Parameters:
    ///   - resource: file name without extension (e.g. `frame1`).
    ///   - ext: file extension (e.g. `png`).
    ///   - slug: theme slug (e.g. `elevator`).
    ///   - family: widget family folder (`small`/`medium`/`large`). iOS themed assets live under
    ///             `small`, so that's the default probe.
    static func url(forResource resource: String,
                    withExtension ext: String,
                    slug: String,
                    family: String = "small") -> URL? {
        let fm = FileManager.default
        let fileName = "\(resource).\(ext)"
        let base = WidgetPaths.templateDirectory(slug: slug)

        let candidates = [
            base.appendingPathComponent(family).appendingPathComponent(fileName),
            base.appendingPathComponent(fileName),
            base.appendingPathComponent("small").appendingPathComponent(fileName)
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            return url
        }

        // Fall back to anything matching shipped in the app bundle (kept for assets we choose to
        // bundle for offline use).
        if let bundled = Bundle.main.url(forResource: resource, withExtension: ext,
                                         subdirectory: "WidgetTemplates/\(slug)/\(family)") {
            return bundled
        }
        return nil
    }

    /// Whether a theme slug has been downloaded/installed (any file present in its directory).
    static func isInstalled(slug: String) -> Bool {
        let dir = WidgetPaths.templateDirectory(slug: slug)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }
}
