import Foundation
import Observation

@MainActor
@Observable
final class WidgetBundleStore {
    static let shared = WidgetBundleStore()

    private(set) var inFlight: Set<String> = []
    private var inFlightTasks: [String: Task<URL, Error>] = [:]

    private init() {}

    func isInstalled(slug: String) -> Bool {
        WidgetAssetResolver.isInstalled(slug: slug)
    }

    @discardableResult
    func ensureInstalled(slug: String, bundleURL: URL?) async throws -> URL {
        let dir = WidgetPaths.templateDirectory(slug: slug)
        if isInstalled(slug: slug) { return dir }
        guard let bundleURL else {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.app.error("Widget dir create failed [\(slug, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
            return dir
        }
        if let existing = inFlightTasks[slug] { return try await existing.value }
        let task = Task<URL, Error> { try await self.install(slug: slug, bundleURL: bundleURL, into: dir) }
        inFlightTasks[slug] = task
        inFlight.insert(slug)
        defer { inFlightTasks[slug] = nil; inFlight.remove(slug) }
        return try await task.value
    }

    private func install(slug: String, bundleURL: URL, into dir: URL) async throws -> URL {
        let data = try await WallpaperAPI.shared.downloadData(from: bundleURL)
        let staging = WidgetPaths.templatesRoot
            .appendingPathComponent(".staging-\(slug)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let written = ZipExtractor.extractTree(from: data, to: staging)
        guard written > 0 else {
            throw WallpaperAPI.APIError.decoding(NSError(domain: "WidgetBundleStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Empty or unreadable widget bundle."]))
        }

        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagingRoot(staging), to: dir)
        Log.app.debug("Installed widget bundle \(slug, privacy: .public): \(written) files")
        return dir
    }

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
