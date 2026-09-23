import AVFoundation
import CryptoKit
import Foundation
import Security

enum LockScreenAerial {
    enum Failure: LocalizedError {
        case unsupported
        case notConfigured
        case transcodeFailed(String?)
        case installFailed(String)
        case retireFailed(String)
        case lost

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return String(localized: "The animated lock screen needs a build of WallPics that runs outside the App Sandbox.")
            case .notConfigured:
                return String(localized: "macOS wallpaper store not found — pick any Aerial wallpaper once in System Settings, then try again.")
            case .transcodeFailed:
                return String(localized: "Couldn't prepare the lock screen clip.")
            case .installFailed:
                return String(localized: "Couldn't install the lock screen clip.")
            case .lost:
                return String(localized: "macOS replaced the lock screen clip — set the wallpaper again.")
            case .retireFailed:
                return String(localized: "Couldn't restore the original lock screen wallpaper.")
            }
        }

        var detail: String {
            switch self {
            case .transcodeFailed(let d): return d ?? "transcode failed"
            case .installFailed(let d), .retireFailed(let d): return d
            case .unsupported: return "sandboxed"
            case .notConfigured: return "wallpaper store missing"
            case .lost: return "aerial replaced after install"
            }
        }
    }

    struct State: Codable, Equatable {
        var slot: String
        var backup: String?
        var assetPath: String
        var clipSize: Int?
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var wallpaperRoot: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
    }
    private static var aerialsDir: URL {
        wallpaperRoot.appendingPathComponent("aerials/videos", isDirectory: true)
    }
    private static var indexPlist: URL { wallpaperRoot.appendingPathComponent("Store/Index.plist") }
    private static var indexV2Plist: URL { wallpaperRoot.appendingPathComponent("Store/Index_v2.plist") }
    private static var manifestFile: URL { wallpaperRoot.appendingPathComponent("aerials/manifest/entries.json") }
    private static var supportFolder: URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent("WallpicsMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private static var stateFile: URL? { supportFolder?.appendingPathComponent("lockscreen.json") }
    private static var clipCacheDir: URL? {
        guard let folder = supportFolder?.appendingPathComponent("LockScreenClips", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let backupTag = "wallpicsbak"
    private static let tempPrefix = ".wpls-"
    static let minimumClipSeconds: Double = 60
    static let clipCacheLimit = 3

    static var isSandboxed: Bool {
        if let task = SecTaskCreateFromSelf(nil),
           let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) {
            return (value as? Bool) == true
        }
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var isSupported: Bool {
        !isSandboxed
            && FileManager.default.fileExists(atPath: wallpaperRoot.path)
            && FileManager.default.isWritableFile(atPath: wallpaperRoot.path)
    }

    static var isConfigured: Bool {
        FileManager.default.fileExists(atPath: indexPlist.path)
            || FileManager.default.fileExists(atPath: indexV2Plist.path)
    }

    static func currentState() -> State? {
        guard let file = stateFile, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static var isActive: Bool { currentState() != nil }

    static func isInstalled(assetPath: String) -> Bool {
        guard isSupported, let state = currentState(), state.assetPath == assetPath,
              let slotSize = fileSize(atPath: state.slot)
        else { return false }
        if let expected = state.clipSize, expected != slotSize { return false }
        let slotID = URL(fileURLWithPath: state.slot).deletingPathExtension().lastPathComponent
        guard let root = try? loadIndex() else { return false }
        return LockScreenIndex.desktopPoints(to: slotID, in: root)
    }

    private static func fileSize(atPath path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    static func cachedClip(for assetPath: String, variant: String = "") -> URL? {
        guard let dir = clipCacheDir, let key = clipCacheKey(for: assetPath, variant: variant) else { return nil }
        let url = dir.appendingPathComponent(key + ".mov")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    static func storeClip(_ clip: URL, for assetPath: String, variant: String = "") -> URL {
        guard let dir = clipCacheDir, let key = clipCacheKey(for: assetPath, variant: variant) else { return clip }
        let url = dir.appendingPathComponent(key + ".mov")
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: clip, to: url)
        } catch {
            Log.engine.error("Lock screen clip cache write failed: \(error.localizedDescription, privacy: .public)")
            return clip
        }
        pruneClipCache(keeping: url)
        return url
    }

    private static func clipCacheKey(for assetPath: String, variant: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: assetPath),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        let seed = "\(assetPath)|\(size)|\(Int(modified.timeIntervalSince1970))|\(variant)"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCacheEntry(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return url.pathExtension == "mov" && name.count == 64 && name.allSatisfy { $0.isHexDigit }
    }

    static func isCachedClip(_ url: URL) -> Bool {
        guard let dir = clipCacheDir else { return false }
        return url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL && isCacheEntry(url)
    }

    private static func pruneClipCache(keeping newest: URL) {
        guard let dir = clipCacheDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let dated = files
            .filter { isCacheEntry($0) && $0 != newest }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(clipCacheLimit - 1) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func install(clip: URL, assetPath: String) async throws {
        guard isSupported else { throw Failure.unsupported }
        guard isConfigured else { throw Failure.notConfigured }
        let id = try resolveAerialID()
        let slot = aerialsDir.appendingPathComponent(id + ".mov")
        try? FileManager.default.createDirectory(at: aerialsDir, withIntermediateDirectories: true)

        var backup: URL?
        if let existing = currentState(), existing.slot == slot.path {
            backup = existing.backup.map { URL(fileURLWithPath: $0) }
        } else if FileManager.default.fileExists(atPath: slot.path) {
            let b = slot.deletingPathExtension().appendingPathExtension(backupTag).appendingPathExtension("mov")
            if !FileManager.default.fileExists(atPath: b.path) {
                try FileManager.default.copyItem(at: slot, to: b)
            }
            backup = b
        }
        try Task.checkCancellation()
        let state = State(slot: slot.path, backup: backup?.path, assetPath: assetPath, clipSize: fileSize(atPath: clip.path))
        try writeState(state)
        do {
            try atomicReplace(slot, with: clip)
            try Task.checkCancellation()
            try selectAerialAsDesktop(id)
            guard let root = try? loadIndex(), LockScreenIndex.desktopPoints(to: id, in: root) else {
                throw Failure.installFailed("Index.plist does not point at \(id) after write")
            }
        } catch {
            Log.engine.error("Lock screen install failed, rolling back: \(error.localizedDescription, privacy: .public)")
            rollBack(state)
            throw error
        }
        reloadDaemons()
        Log.engine.info("Lock screen clip installed into aerial \(id, privacy: .public)")
    }

    static func retire() async throws {
        guard let state = currentState() else { return }
        let slot = URL(fileURLWithPath: state.slot)
        do {
            if let backupPath = state.backup {
                let backup = URL(fileURLWithPath: backupPath)
                if FileManager.default.fileExists(atPath: backup.path) {
                    try atomicReplace(slot, with: backup)
                    try? FileManager.default.removeItem(at: backup)
                }
            } else {
                try? FileManager.default.removeItem(at: slot)
            }
        } catch {
            Log.engine.error("Lock screen retire failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.retireFailed(error.localizedDescription)
        }
        if let file = stateFile { try? FileManager.default.removeItem(at: file) }
        reloadDaemons()
        Log.engine.info("Lock screen clip retired")
    }

    private static func rollBack(_ state: State) {
        guard currentState() == state else {
            Log.engine.notice("Lock screen rollback skipped: a newer install owns the slot")
            return
        }
        let slot = URL(fileURLWithPath: state.slot)
        if let backupPath = state.backup, FileManager.default.fileExists(atPath: backupPath) {
            if (try? atomicReplace(slot, with: URL(fileURLWithPath: backupPath))) != nil {
                try? FileManager.default.removeItem(atPath: backupPath)
            } else {
                Log.engine.error("Lock screen rollback could not restore \(state.slot, privacy: .public); backup kept")
                return
            }
        } else if state.backup == nil {
            try? FileManager.default.removeItem(at: slot)
        }
        if let file = stateFile { try? FileManager.default.removeItem(at: file) }
    }

    static func transcodeToHEVC(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first,
              let dstVideo = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.transcodeFailed("no video track") }
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else { throw Failure.transcodeFailed("zero duration") }
        let range = CMTimeRange(start: .zero, duration: duration)
        let loops = min(60, max(1, Int(ceil(minimumClipSeconds / duration.seconds))))
        var cursor = CMTime.zero
        for _ in 0..<loops {
            try dstVideo.insertTimeRange(range, of: srcVideo, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        dstVideo.preferredTransform = try await srcVideo.load(.preferredTransform)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw Failure.transcodeFailed("no HEVC export session")
        }
        export.outputURL = out
        export.outputFileType = .mov
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                export.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            export.cancelExport()
        }
        guard export.status == .completed, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            if Task.isCancelled || export.status == .cancelled { throw CancellationError() }
            let detail = export.error?.localizedDescription ?? "status \(export.status.rawValue)"
            Log.engine.error("Lock screen transcode failed: \(detail, privacy: .public)")
            throw Failure.transcodeFailed(detail)
        }
        return out
    }

    private static func resolveAerialID() throws -> String {
        if let state = currentState() {
            let id = URL(fileURLWithPath: state.slot).deletingPathExtension().lastPathComponent
            if FileManager.default.fileExists(atPath: state.slot) { return id }
        }
        if let root = try? loadIndex() {
            for id in LockScreenIndex.collectAerialIDs(in: root, section: "Desktop") {
                let mov = aerialsDir.appendingPathComponent(id + ".mov")
                if FileManager.default.fileExists(atPath: mov.path) { return id }
            }
        }
        if let id = anyDownloadedAerialID() ?? manifestAerialID() { return id }
        throw Failure.notConfigured
    }

    private static func anyDownloadedAerialID() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: aerialsDir.path) else { return nil }
        return files.first { $0.hasSuffix(".mov") && !$0.contains(backupTag) && !$0.hasPrefix(tempPrefix) }
            .map { ($0 as NSString).deletingPathExtension }
    }

    private static func manifestAerialID() -> String? {
        guard let data = try? Data(contentsOf: manifestFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        return assets.compactMap { $0["id"] as? String }.first { !$0.isEmpty }
    }

    private static func selectAerialAsDesktop(_ id: String) throws {
        guard isConfigured else { throw Failure.notConfigured }
        let choice = try LockScreenIndex.aerialChoice(id)
        for plist in [indexPlist, indexV2Plist] where FileManager.default.fileExists(atPath: plist.path) {
            let data = try Data(contentsOf: plist)
            guard let root = try PropertyListSerialization.propertyList(
                from: data, options: [.mutableContainersAndLeaves], format: nil) as? NSMutableDictionary
            else { throw Failure.installFailed("\(plist.lastPathComponent) root is not a dictionary") }
            guard LockScreenIndex.applyAerialChoice(in: root, choice: choice) > 0 else {
                throw Failure.installFailed("no Desktop/Idle choices found in \(plist.lastPathComponent)")
            }
            let out = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            try out.write(to: plist, options: .atomic)
        }
    }

    private static func loadIndex() throws -> Any {
        let file = FileManager.default.fileExists(atPath: indexPlist.path) ? indexPlist : indexV2Plist
        let data = try Data(contentsOf: file)
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private static func atomicReplace(_ dst: URL, with src: URL) throws {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(tempPrefix + UUID().uuidString + ".mov")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: src, to: tmp)
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
    }

    private static func writeState(_ state: State) throws {
        guard let file = stateFile else { throw Failure.installFailed("no Application Support folder") }
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: .atomic)
    }

    private static func reloadDaemons() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent", "WallpaperAerialsExtension", "idleassetsd"]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                Log.engine.error("Wallpaper daemon reload exited with \(task.terminationStatus, privacy: .public)")
            }
        } catch {
            Log.engine.error("Wallpaper daemon reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
