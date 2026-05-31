import Foundation
import os

actor CacheManager {
    static let shared = CacheManager()

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let maxSize: Int64
    private var sweepTimer: Timer?
    private var cacheEnabled = true

    /// Folders that hold actual cached media. Marker folders (Favorites/Downloaded) are
    /// never swept — deleting a 0-byte marker would silently drop a favorite.
    private let mediaFolders: [Folder] = [.images, .videos, .shaders, .animations, .firstFrames]

    enum Folder: String {
        case images = "Images"
        case videos = "Videos"
        case shaders = "Shaders"
        case animations = "Animations"
        case firstFrames = "FirstFrames"
        case favorites = "Favorites"
        case downloaded = "Downloaded"
        case imports = "Imports"          // user-uploaded asset files
        case importMeta = "ImportMeta"    // JSON metadata for each import
    }

    init(maxSize: Int64 = 500 * 1024 * 1024) {
        self.maxSize = maxSize
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rootURL = support.appendingPathComponent("WallpicsMac", isDirectory: true)
        Self.bootstrapFolders(rootURL: rootURL)
    }

    private static func bootstrapFolders(rootURL: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for folder in [Folder.images, .videos, .shaders, .animations, .firstFrames, .favorites, .downloaded, .imports, .importMeta] {
            try? fm.createDirectory(at: rootURL.appendingPathComponent(folder.rawValue, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    var root: URL { rootURL }

    func folderURL(_ folder: Folder) -> URL {
        rootURL.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    nonisolated func cacheRoot() -> URL { rootURL }

    func createIfNeeded() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for folder in [Folder.images, .videos, .shaders, .animations, .firstFrames, .favorites, .downloaded, .imports, .importMeta] {
            try fileManager.createDirectory(at: folderURL(folder), withIntermediateDirectories: true)
        }
    }

    func setCacheEnabled(_ enabled: Bool) {
        cacheEnabled = enabled
        enforceLimit()
    }

    func startPeriodicSweep(cacheEnabled: Bool, interval: TimeInterval = 600) {
        self.cacheEnabled = cacheEnabled
        sweepTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { await CacheManager.shared.enforceLimit() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
        enforceLimit()
    }

    func stopPeriodicSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    /// Total bytes across the media folders only.
    func currentSize() -> Int64 {
        mediaEntries().reduce(0) { $0 + $1.size }
    }

    /// Enforce the size policy. Files belonging to an explicitly-downloaded wallpaper (and
    /// therefore the currently-set wallpaper, which is always marked downloaded) are pinned
    /// and never evicted. Non-pinned media is evicted least-recently-used first to fit the
    /// target — `maxSize` when caching is on, 0 (drop all unsaved) when off.
    func enforceLimit() {
        let pinned = downloadedIDs()
        let target: Int64 = cacheEnabled ? maxSize : 0
        let entries = mediaEntries().sorted { $0.accessed > $1.accessed } // newest first

        var kept: Int64 = 0
        for entry in entries {
            if let id = entry.id, pinned.contains(id) { continue } // saved → always keep
            if kept + entry.size <= target {
                kept += entry.size
            } else {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }

    /// IDs that have an explicit Downloaded marker.
    private func downloadedIDs() -> Set<Int> {
        guard let markers = try? fileManager.contentsOfDirectory(atPath: folderURL(.downloaded).path) else { return [] }
        return Set(markers.compactMap(Int.init))
    }

    /// Leading integer of a media filename, e.g. "36547-free.jpg" -> 36547, "12.jpg" -> 12,
    /// "-840-free.jpg" -> -840 (imported wallpapers use negative ids).
    private func leadingID(of filename: String) -> Int? {
        var s = Substring(filename)
        let negative = s.first == "-"
        if negative { s = s.dropFirst() }
        let digits = s.prefix { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        return negative ? -n : n
    }

    private func mediaEntries() -> [(url: URL, id: Int?, size: Int64, accessed: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]
        var result: [(URL, Int?, Int64, Date)] = []
        for folder in mediaFolders {
            guard let items = try? fileManager.contentsOfDirectory(
                at: folderURL(folder),
                includingPropertiesForKeys: Array(keys)
            ) else { continue }
            for url in items {
                let attrs = try? url.resourceValues(forKeys: keys)
                guard attrs?.isRegularFile == true else { continue }
                result.append((url, leadingID(of: url.lastPathComponent),
                               Int64(attrs?.fileSize ?? 0), attrs?.contentAccessDate ?? .distantPast))
            }
        }
        return result
    }

    // MARK: - Favorites
    //
    // Each favorite is persisted as Favorites/{id}.json holding the full Wallpaper. This makes
    // the Favorites tab self-sufficient — it survives relaunch and doesn't depend on which
    // Browse pages happen to be loaded in memory.

    func setFavorite(_ wallpaper: Wallpaper, favorite: Bool) {
        let url = favoriteFileURL(wallpaper.id)
        if favorite {
            if let data = try? JSONEncoder().encode(wallpaper) {
                try? data.write(to: url, options: .atomic)
            }
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    func isFavorite(_ wallpaperID: Int) -> Bool {
        fileManager.fileExists(atPath: favoriteFileURL(wallpaperID).path)
    }

    /// All favorited wallpapers, most-recently-added first.
    func favoriteWallpapers() -> [Wallpaper] {
        let keys: Set<URLResourceKey> = [.creationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: folderURL(.favorites), includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (Wallpaper, Date)? in
                guard let data = try? Data(contentsOf: url),
                      let wp = try? decoder.decode(Wallpaper.self, from: data) else { return nil }
                let created = (try? url.resourceValues(forKeys: keys))?.creationDate ?? .distantPast
                return (wp, created)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func favoriteFileURL(_ id: Int) -> URL {
        folderURL(.favorites).appendingPathComponent("\(id).json")
    }

    // MARK: - Imports (user-uploaded wallpapers)
    //
    // The asset file lives in Imports/<id>.<ext>; its metadata (a local Wallpaper) in
    // ImportMeta/<id>.json. Both persist across relaunch and are independent of the API.

    var importsFolder: URL { folderURL(.imports) }

    func saveImport(_ wallpaper: Wallpaper) {
        let url = folderURL(.importMeta).appendingPathComponent("\(wallpaper.id).json")
        if let data = try? JSONEncoder().encode(wallpaper) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// All imported wallpapers, most-recently-added first.
    func importedWallpapers() -> [Wallpaper] {
        let keys: Set<URLResourceKey> = [.creationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: folderURL(.importMeta), includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (Wallpaper, Date)? in
                guard let data = try? Data(contentsOf: url),
                      let wp = try? decoder.decode(Wallpaper.self, from: data) else { return nil }
                let created = (try? url.resourceValues(forKeys: keys))?.creationDate ?? .distantPast
                return (wp, created)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Remove an import completely: metadata, asset file, thumbnail, favorite marker, AND the
    /// watermarked copies / first-frame / downloaded-pin it produced when set as wallpaper —
    /// otherwise those stay pinned forever and leak disk.
    func removeImport(_ wallpaper: Wallpaper) {
        try? fileManager.removeItem(at: folderURL(.importMeta).appendingPathComponent("\(wallpaper.id).json"))
        if let asset = wallpaper.wallpaperURL, asset.isFileURL {
            try? fileManager.removeItem(at: asset)
        }
        if let thumb = wallpaper.thumbnailURL, thumb.isFileURL {
            try? fileManager.removeItem(at: thumb)
        }
        try? fileManager.removeItem(at: favoriteFileURL(wallpaper.id))
        removeCachedImages(for: wallpaper.id)
        try? fileManager.removeItem(at: folderURL(.firstFrames).appendingPathComponent("\(wallpaper.id).jpg"))
        markDownloaded(wallpaper.id, downloaded: false)
    }

    /// Remove any cached image files for a wallpaper id (all watermark variants), so
    /// re-applying after a Pro upgrade doesn't leave a pinned orphan behind.
    func removeCachedImages(for wallpaperID: Int) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: folderURL(.images).path) else { return }
        for name in items where leadingID(of: name) == wallpaperID {
            try? fileManager.removeItem(at: folderURL(.images).appendingPathComponent(name))
        }
    }

    func markDownloaded(_ wallpaperID: Int, downloaded: Bool) {
        let url = folderURL(.downloaded).appendingPathComponent(String(wallpaperID))
        if downloaded {
            try? Data().write(to: url)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    func isDownloaded(_ wallpaperID: Int) -> Bool {
        fileManager.fileExists(atPath: folderURL(.downloaded).appendingPathComponent(String(wallpaperID)).path)
    }
}
