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
    }

    // MARK: - Public API

    func setStaticImage(_ url: URL) {
        clearWindows()
        currentKind = .image
        currentAssetURL = url
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
        guard kind != .image else {
            applyStaticAcrossScreens(url: url)
            return
        }
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
        applyPauseStateToWindows()
    }

    @objc private func systemWillSleep() {
        setPaused(true, reason: .screenSleep)
    }

    @objc private func systemDidWake() {
        setPaused(false, reason: .screenSleep)
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
