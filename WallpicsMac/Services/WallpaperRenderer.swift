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
    private var needsWatermark = false
    private var watermarkIcon: NSImage?

    private(set) var isPaused = false
    private(set) var pauseReasons: Set<PauseReason> = []

    enum PauseReason: Hashable {
        case userToggle, lowPower, onBattery, screenSleep
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

    func setStaticImage(_ url: URL) {
        clearWindows()
        currentKind = .image
        currentAssetURL = url
        // Static images persist in macOS on their own — drop any animated-restore record so we
        // don't re-apply an old live wallpaper over the user's new static choice next launch.
        ActiveWallpaperStore.clear()
        applyStaticAcrossScreens(url: url)
    }

    func startAnimated(kind: Kind, url: URL, firstFrameStaticURL: URL?, needsWatermark: Bool = false, appIcon: NSImage? = nil) {
        clearWindows()
        currentKind = kind
        currentAssetURL = url
        self.needsWatermark = needsWatermark
        self.watermarkIcon = appIcon

        if let staticURL = firstFrameStaticURL {
            applyStaticAcrossScreens(url: staticURL)
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
        currentKind = nil
        currentAssetURL = nil
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
        // Screen lock/unlock (loginwindow posts these via the distributed center).
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
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
