import Foundation

/// Remembers the currently-active **animated/shader** wallpaper so it can be restored on the next
/// launch (after a restart/login). Without this, an animated wallpaper's desktop windows die with
/// the process and the desktop falls back to the low-res first-frame poster — which reads as
/// "the wallpaper quality dropped". Static images are intentionally NOT tracked here: macOS keeps
/// the desktop image itself across launches, so they restore on their own.
///
/// The record lives in the app-support root (never touched by the cache sweep). The referenced
/// asset/poster files are pinned in the cache (Downloaded marker) so they survive eviction.
enum ActiveWallpaperStore {
    struct Record: Codable {
        var kind: String          // WallpaperRenderer.Kind.rawName (video/shader/animation/gif)
        var assetPath: String     // absolute path to the playable asset on disk
        var posterPath: String?   // absolute path to the static first-frame, if any
        var watermarked: Bool     // whether the free-tier watermark was applied when it was set
    }

    private static var fileURL: URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent("WallpicsMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ActiveWallpaper.json")
    }

    static func save(_ record: Record) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Record? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        return record
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
