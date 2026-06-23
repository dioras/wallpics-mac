import Foundation

enum WidgetAssetResolver {
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

        if let bundled = Bundle.main.url(forResource: resource, withExtension: ext,
                                         subdirectory: "WidgetTemplates/\(slug)/\(family)") {
            return bundled
        }
        return nil
    }

    static func isInstalled(slug: String) -> Bool {
        let dir = WidgetPaths.templateDirectory(slug: slug)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }
}
