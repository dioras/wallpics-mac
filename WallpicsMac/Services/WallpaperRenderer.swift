import Cocoa
import AVFoundation
import os

@MainActor
final class WallpaperRenderer {
    static let shared = WallpaperRenderer()

    enum Kind {
        case image, video, shader, animation, gif

        static func detect(from url: URL) -> Kind? {
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg", "png", "heic", "bmp", "tiff": return .image
            case "mp4", "mov", "m4v", "avi", "mkv", "webm": return .video
            case "msl", "metal": return .shader
            case "riv": return .animation
            case "gif": return .gif
            default: return nil
            }
        }

        /// Stable string for persistence (so the active animated wallpaper survives a relaunch).
        var rawName: String {
            switch self {
            case .image: return "image"
            case .video: return "video"
            case .shader: return "shader"
            case .animation: return "animation"
            case .gif: return "gif"
            }
        }

        init?(rawName: String) {
            switch rawName {
            case "image": self = .image
            case "video": self = .video
            case "shader": self = .shader
            case "animation": self = .animation
            case "gif": self = .gif
            default: return nil
            }
        }
    }

    private var activeWindows: [NSWindow] = []
    private var currentKind: Kind?
    private var currentAssetURL: URL?
    private var currentPosterURL: URL?
    private var needsWatermark = false
    private var watermarkIcon: NSImage?
    private var activeGeneration = 0

    private(set) var isPaused = false
    private(set) var pauseReasons: Set<PauseReason> = []

    enum PauseReason: Hashable {
        case userToggle, lowPower, onBattery, screenSleep, displaySleep, screenLocked
    }

    init() {
        registerSystemObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Public API

    func setStaticImage(_ url: URL, source: URL? = nil, watermarked: Bool = false) {
        clearWindows()
        activeGeneration += 1
        currentKind = .image
        currentAssetURL = url
        currentPosterURL = nil
        // Static images persist in macOS on their own — replace any animated-restore record so we
        // don't re-apply an old live wallpaper over the user's new static choice next launch.
        if let source {
            ActiveWallpaperStore.save(.init(kind: Kind.image.rawName, assetPath: url.path, posterPath: nil,
                                            watermarked: watermarked, sourcePath: source.path))
        } else {
            ActiveWallpaperStore.clear()
        }
        applyStaticAcrossScreens(url: url)
        LockScreenService.shared.wallpaperDidBecomeStatic()
    }

    func startAnimated(kind: Kind, url: URL, firstFrameStaticURL: URL?, needsWatermark: Bool = false, appIcon: NSImage? = nil) {
        clearWindows()
        activeGeneration += 1
        currentKind = kind
        currentAssetURL = url
        currentPosterURL = firstFrameStaticURL
        self.needsWatermark = needsWatermark
        self.watermarkIcon = appIcon

        let lockScreen = LockScreenService.shared
        if let staticURL = firstFrameStaticURL, !lockScreen.willInstallImmediately(kind: kind, assetURL: url) {
            applyStaticAcrossScreens(url: staticURL)
            lockScreen.noteDesktopPictureApplied()
        }

        for screen in NSScreen.screens {
            addAnimatedWindow(kind: kind, url: url, screen: screen)
        }

        applyPauseStateToWindows()

        // Remember this animated/shader wallpaper so we can bring it back after a relaunch.
        ActiveWallpaperStore.save(.init(
            kind: kind.rawName,
            assetPath: url.path,
            posterPath: firstFrameStaticURL?.path,
            watermarked: needsWatermark
        ))
        LockScreenService.shared.sync(kind: kind, assetURL: url)
    }

    func reapplyDesktopChoice() {
        if case .image = currentKind, let url = currentAssetURL {
            applyStaticAcrossScreens(url: url)
        } else if let poster = currentPosterURL {
            applyStaticAcrossScreens(url: poster)
            LockScreenService.shared.noteDesktopPictureApplied()
        }
    }

    /// Re-apply the last animated/shader wallpaper saved by `startAnimated`, if its files are still
    /// on disk. Called once at launch so a live wallpaper survives a restart (paired with the
    /// Login Item). Static images aren't handled here — macOS restores those itself.
    func restoreLast() {
        guard let record = ActiveWallpaperStore.load(),
              let kind = Kind(rawName: record.kind),
              kind != .image,
              FileManager.default.fileExists(atPath: record.assetPath)
        else { return }

        let asset = URL(fileURLWithPath: record.assetPath)
        let poster = record.posterPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        startAnimated(
            kind: kind,
            url: asset,
            firstFrameStaticURL: poster,
            needsWatermark: record.watermarked,
            appIcon: NSApplication.shared.applicationIconImage
        )
        Log.engine.info("Restored animated wallpaper on launch (\(kind.rawName, privacy: .public))")
    }

    /// Bring the active wallpaper's watermark in line with the subscription: drop it once the user
    /// is Pro, put it back when Pro lapses. Covers the live overlay, the desktop/lock-screen poster
    /// and baked static images. No-op when the active wallpaper already matches.
    func refreshWatermark(isPro: Bool) {
        guard let record = ActiveWallpaperStore.load(), record.watermarked == isPro,
              let kind = Kind(rawName: record.kind) else { return }
        let generation = activeGeneration
        Task {
            if kind == .image {
                await reapplyStatic(record: record, isPro: isPro, generation: generation)
            } else {
                await reapplyAnimated(kind: kind, record: record, isPro: isPro, generation: generation)
            }
        }
    }

    /// Wallpaper ids whose cached files are on screen right now (desktop pictures + the live
    /// wallpaper record), so the cache can keep exactly those pinned.
    func activeWallpaperIDs() -> Set<Int> {
        let root = CacheManager.shared.cacheRoot().standardizedFileURL.path + "/"
        var urls = NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        if let record = ActiveWallpaperStore.load() {
            urls.append(URL(fileURLWithPath: record.assetPath))
            if let poster = record.posterPath { urls.append(URL(fileURLWithPath: poster)) }
        }
        return Set(urls.map(\.standardizedFileURL)
            .filter { $0.path.hasPrefix(root) }
            .compactMap { CacheManager.wallpaperID(fromFilename: $0.lastPathComponent) })
    }

    private func reapplyStatic(record: ActiveWallpaperStore.Record, isPro: Bool, generation: Int) async {
        let current = URL(fileURLWithPath: record.assetPath).standardizedFileURL
        guard let sourcePath = record.sourcePath, FileManager.default.fileExists(atPath: sourcePath),
              let id = CacheManager.wallpaperID(fromFilename: current.lastPathComponent),
              NSScreen.screens.contains(where: { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path == current.path })
        else { return }
        let source = URL(fileURLWithPath: sourcePath)
        let destination = await CacheManager.shared.folderURL(.images)
            .appendingPathComponent("\(id)-\(isPro ? "pro" : "free").jpg")
        guard generation == activeGeneration, destination.standardizedFileURL.path != current.path else { return }
        do {
            try WatermarkService.applyIfNeeded(
                to: source,
                destinationURL: destination,
                isPro: isPro,
                appIcon: NSApplication.shared.applicationIconImage,
                screenAspects: NSScreen.screens.map { $0.frame.width / max(1, $0.frame.height) }
            )
            setStaticImage(destination, source: source, watermarked: !isPro)
            try? FileManager.default.removeItem(at: current)
            Log.engine.info("Static wallpaper re-applied for subscription change (pro: \(isPro, privacy: .public))")
        } catch {
            Log.engine.error("Watermark refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reapplyAnimated(kind: Kind, record: ActiveWallpaperStore.Record, isPro: Bool, generation: Int) async {
        guard currentKind == kind, let asset = currentAssetURL, asset.path == record.assetPath else { return }
        let icon = NSApplication.shared.applicationIconImage
        let oldPoster = currentPosterURL
        var poster = oldPoster
        let idSource = (record.posterPath.map { URL(fileURLWithPath: $0) } ?? asset).lastPathComponent
        if let content = await Self.posterContent(kind: kind, asset: asset),
           let id = CacheManager.wallpaperID(fromFilename: idSource) {
            let target = Self.posterTarget()
            let dest = await CacheManager.shared.folderURL(.firstFrames)
                .appendingPathComponent("\(id)-\(isPro ? "pro" : "free").png")
            if WallpaperPoster.write(content: content, targetSize: target.size, scale: target.scale,
                                     isPro: isPro, appIcon: icon, to: dest) {
                poster = dest
            }
        }
        guard generation == activeGeneration else { return }
        startAnimated(kind: kind, url: asset, firstFrameStaticURL: poster, needsWatermark: !isPro, appIcon: icon)
        if let oldPoster, oldPoster != poster { try? FileManager.default.removeItem(at: oldPoster) }
        Log.engine.info("Live wallpaper re-applied for subscription change (pro: \(isPro, privacy: .public))")
    }

    private static func posterContent(kind: Kind, asset: URL) async -> CGImage? {
        switch kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            return try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        case .shader:
            guard let source = try? String(contentsOf: asset, encoding: .utf8), !source.isEmpty else { return nil }
            return ShaderSnapshot.render(shaderSource: source, pixelSize: posterTarget().size)
        case .gif:
            return NSImage(contentsOf: asset)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case .animation, .image:
            return nil
        }
    }

    private static func posterTarget() -> (size: CGSize, scale: CGFloat) {
        let best = NSScreen.screens.max {
            ($0.frame.width * $0.backingScaleFactor * $0.frame.height) <
            ($1.frame.width * $1.backingScaleFactor * $1.frame.height)
        }
        if let s = best {
            return (CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor),
                    s.backingScaleFactor)
        }
        return (CGSize(width: 3840, height: 2160), 2)
    }

    /// Create one animated window for a screen, attach the live watermark overlay if needed.
    private func addAnimatedWindow(kind: Kind, url: URL, screen: NSScreen) {
        let window = makeWindow(kind: kind, url: url, screen: screen)
        if needsWatermark {
            WatermarkOverlay.attach(to: window, appIcon: watermarkIcon)
        }
        window.orderBack(nil)
        activeWindows.append(window)
    }

    func clear() {
        clearWindows()
        activeGeneration += 1
        currentKind = nil
        currentAssetURL = nil
        currentPosterURL = nil
    }

    // MARK: - Pause / resume

    func setPaused(_ paused: Bool, reason: PauseReason) {
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        isPaused = !pauseReasons.isEmpty
        applyPauseStateToWindows()
    }

    private func applyPauseStateToWindows() {
        for window in activeWindows {
            guard let control = window as? WallpaperWindowControl else { continue }
            if isPaused { control.pause() } else { control.resume() }
        }
    }

    // MARK: - Multi-screen

    @objc private func screensChanged() {
        guard let kind = currentKind, let url = currentAssetURL else { return }
        if kind == .image {
            applyStaticAcrossScreens(url: url)
            return
        }
        reconcileAnimatedWindows(kind: kind, url: url)
        LockScreenService.shared.reassert()
    }

    /// Make sure the live wallpaper still covers every screen and sits at desktop level. Safe to
    /// call repeatedly — it drops windows for disconnected screens, adds any that are missing, and
    /// re-asserts z-order. Used after a display change, wake, OR screen unlock so the animation
    /// reliably comes back (macOS can tear down or re-order desktop windows across those events).
    private func reconcileAnimatedWindows(kind: Kind, url: URL) {
        let activeScreens = Set(NSScreen.screens.map { $0.localizedName })
        activeWindows.removeAll { window in
            let stillActive = window.screen.map { activeScreens.contains($0.localizedName) } ?? false
            if !stillActive { (window as? WallpaperWindowControl)?.stop() }
            return !stillActive
        }
        let coveredScreens = Set(activeWindows.compactMap { $0.screen?.localizedName })
        for screen in NSScreen.screens where !coveredScreens.contains(screen.localizedName) {
            addAnimatedWindow(kind: kind, url: url, screen: screen)
        }
        // Re-assert desktop-level z-order for windows that survived (unlock can shuffle them).
        for window in activeWindows { window.orderBack(nil) }
        applyPauseStateToWindows()
    }

    /// Re-apply whatever animated wallpaper is currently active (no-op for static / none).
    private func reassertCurrentWallpaper() {
        guard let kind = currentKind, kind != .image, let url = currentAssetURL else { return }
        reconcileAnimatedWindows(kind: kind, url: url)
        LockScreenService.shared.reassert()
    }

    @objc private func systemWillSleep() {
        setPaused(true, reason: .screenSleep)
    }

    @objc private func systemDidWake() {
        setPaused(false, reason: .screenSleep)
        reassertCurrentWallpaper()
    }

    /// macOS shows the desktop *picture* (the static poster) on the lock screen, not our live
    /// window. On unlock we re-assert the animation so it resumes for the returning session.
    @objc private func screenUnlocked() {
        setPaused(false, reason: .screenLocked)
        reassertCurrentWallpaper()
    }

    @objc private func screenLocked() {
        setPaused(true, reason: .screenLocked)
    }

    @objc private func displaysDidSleep() {
        setPaused(true, reason: .displaySleep)
    }

    @objc private func displaysDidWake() {
        setPaused(false, reason: .displaySleep)
        reassertCurrentWallpaper()
    }

    private func registerSystemObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displaysDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displaysDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        // Screen lock/unlock (loginwindow posts these via the distributed center).
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    // MARK: - Internals

    private func applyStaticAcrossScreens(url: URL) {
        let workspace = NSWorkspace.shared
        for screen in NSScreen.screens {
            try? workspace.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    private func makeWindow(kind: Kind, url: URL, screen: NSScreen) -> NSWindow {
        switch kind {
        case .video: return VideoWallpaperWindow(screen: screen, videoURL: url)
        case .shader: return ShaderWallpaperWindow(screen: screen, shaderURL: url)
        case .animation: return AnimationWallpaperWindow(screen: screen, animationURL: url)
        case .gif: return GIFWallpaperWindow(screen: screen, gifURL: url)
        case .image:
            // Image path uses setDesktopImageURL — no window needed.
            return NSWindow.makeDesktopLevel(for: screen)
        }
    }

    private func clearWindows() {
        for window in activeWindows {
            (window as? WallpaperWindowControl)?.stop()
            window.orderOut(nil)
        }
        activeWindows.removeAll()
    }
}
