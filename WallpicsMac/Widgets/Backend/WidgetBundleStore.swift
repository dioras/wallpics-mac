import Foundation
import Observation

/// Downloads + unzips backend widget bundles into `WidgetPaths.templatesRoot/<slug>`, ported from
/// the iOS `WidgetBundleStore`. Themed widgets (elevator, garage-door, …) and Widgify templates
/// ship their assets (`config.json`, `frameN.png`, animated WebP) as a zip; the renderer resolves
/// them from disk via `WidgetAssetResolver` once installed.
@MainActor
@Observable
final class WidgetBundleStore {
    static let shared = WidgetBundleStore()

    /// Slugs currently downloading, so the UI can show progress and we don't double-fetch.
    private(set) var inFlight: Set<String> = []
    /// One install task per slug, so concurrent callers for the same widget share the download and
    /// all await the *same* completed install (rather than a second caller getting an empty dir).
    private var inFlightTasks: [String: Task<URL, Error>] = [:]

    private init() {}

    /// True if the bundle for `slug` is already on disk.
    func isInstalled(slug: String) -> Bool {
        WidgetAssetResolver.isInstalled(slug: slug)
    }

    /// Ensure a bundle is installed, downloading + extracting if needed. Idempotent and safe to
    /// call repeatedly (and concurrently for the same slug). Returns the installed directory, or
    /// throws on a hard failure.
    @discardableResult
    func ensureInstalled(slug: String, bundleURL: URL?) async throws -> URL {
        let dir = WidgetPaths.templateDirectory(slug: slug)
        if isInstalled(slug: slug) { return dir }
        guard let bundleURL else {
            // Nothing to download (e.g. a widget with no remote assets) — hand back the (empty) dir.
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.app.error("Widget dir create failed [\(slug, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
            return dir
        }
        // Coalesce concurrent installs for the same slug onto one task.
        if let existing = inFlightTasks[slug] { return try await existing.value }
        let task = Task<URL, Error> { try await self.install(slug: slug, bundleURL: bundleURL, into: dir) }
        inFlightTasks[slug] = task
        inFlight.insert(slug)
        defer { inFlightTasks[slug] = nil; inFlight.remove(slug) }
        return try await task.value
    }

    private func install(slug: String, bundleURL: URL, into dir: URL) async throws -> URL {
        let data = try await WallpaperAPI.shared.downloadData(from: bundleURL)
        // Extract into a staging dir first, then move atomically, so a half-written bundle never
        // looks "installed".
        let staging = WidgetPaths.templatesRoot
            .appendingPathComponent(".staging-\(slug)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let written = ZipExtractor.extractTree(from: data, to: staging)
        guard written > 0 else {
            throw WallpaperAPI.APIError.decoding(NSError(domain: "WidgetBundleStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Empty or unreadable widget bundle."]))
        }

        // Replace any previous install.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagingRoot(staging), to: dir)
        Log.app.debug("Installed widget bundle \(slug, privacy: .public): \(written) files")
        return dir
    }

    /// Some bundles wrap their contents in a single top-level folder; if so, treat that folder as
    /// the bundle root so asset paths line up with `WidgetAssetResolver`'s probes.
    private func stagingRoot(_ staging: URL) -> URL {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey]),
              contents.count == 1,
              let only = contents.first,
              (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return staging }
        return only
    }
}
