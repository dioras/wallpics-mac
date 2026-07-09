import SwiftUI
import ImageIO

/// Plays an animated WebP (the live-wallpaper grid thumbnails) inline. ImageIO decodes WebP
/// natively on macOS 11+, so this needs no dependencies: frames are decoded once — downsampled
/// to thumbnail size and strided to a frame cap so a grid of cells stays cheap — then looped
/// with a timer. Lifecycle is tied to the view: decoding is cancelled and frames are released
/// when the cell scrolls away (LazyVGrid recycles cells, so off-screen cards cost nothing).
struct AnimatedWebPView: NSViewRepresentable {
    let url: URL
    var fallbackURL: URL?
    var isActive: Bool = true
    var maxPixelSize: CGFloat = 360
    /// Shown behind the frames so a failed/slow download reads as a tinted card, never black.
    var placeholderTint: Color = Color(white: 0.14)

    func makeNSView(context: Context) -> WebPPlayerView { WebPPlayerView() }

    func updateNSView(_ view: WebPPlayerView, context: Context) {
        view.setPlaceholder(placeholderTint)
        view.load(url: url, fallbackURL: fallbackURL, maxPixelSize: maxPixelSize)
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: WebPPlayerView, coordinator: ()) {
        view.reset()
    }
}

final class WebPPlayerView: NSView {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()
    private nonisolated static let maxFrames = 24

    /// At most a few simultaneous frame decodes app-wide — a page of cells appearing at once
    /// otherwise floods the CPU and the whole app stutters.
    private static let decodeGate = AsyncLimiter(limit: 3)

    private var currentURL: URL?
    private var pendingFallbackURL: URL?
    private var pendingMaxPixelSize: CGFloat = 360
    private var isActive = false
    private var frames: [CGImage] = []
    private var frameDelay: TimeInterval = 1.0 / 24.0
    private var frameIndex = 0
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    /// Solid tint behind the frames so a slow/failed download shows a colored card, not black.
    func setPlaceholder(_ color: Color) {
        let cg = NSColor(color).cgColor
        if layer?.backgroundColor != cg { layer?.backgroundColor = cg }
    }

    func load(url: URL, fallbackURL: URL?, maxPixelSize: CGFloat) {
        guard url != currentURL else { return }
        currentURL = url
        pendingFallbackURL = fallbackURL
        pendingMaxPixelSize = maxPixelSize
        stop()
        loadTask = Task { [weak self] in
            guard let fallbackURL,
                  let fbData = try? await ResilientFetch.data(from: fallbackURL, using: Self.session) else { return }
            let still = await Task.detached(priority: .userInitiated) {
                Self.decodeStill(data: fbData, maxPixelSize: maxPixelSize)
            }.value
            guard let still, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == url, self.frames.isEmpty else { return }
                self.layer?.contents = still
            }
        }
        if isActive { startAnimationIfNeeded() }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if frames.count > 1 {
                startTimerIfAnimated()
            } else {
                startAnimationIfNeeded()
            }
        } else {
            timer?.invalidate()
            timer = nil
            if let first = frames.first {
                frameIndex = 0
                layer?.contents = first
            }
        }
    }

    private func startAnimationIfNeeded() {
        guard animationTask == nil, frames.count <= 1, let url = currentURL else { return }
        let maxPixelSize = pendingMaxPixelSize
        animationTask = Task { [weak self] in
            let data = try? await ResilientFetch.data(from: url, using: Self.session)
            guard !Task.isCancelled, let data else {
                await MainActor.run { [weak self] in self?.animationTask = nil }
                return
            }
            await Self.decodeGate.acquire()
            let decoded = await Task.detached(priority: .utility) {
                Self.decodeFrames(data: data, maxPixelSize: maxPixelSize)
            }.value
            await Self.decodeGate.release()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.animationTask = nil
                guard self.currentURL == url, !decoded.frames.isEmpty else { return }
                self.frames = decoded.frames
                self.frameDelay = decoded.delay
                self.frameIndex = 0
                self.layer?.contents = decoded.frames[0]
                if self.isActive { self.startTimerIfAnimated() }
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        animationTask?.cancel()
        animationTask = nil
        timer?.invalidate()
        timer = nil
        frames = []
    }

    func reset() {
        stop()
        currentURL = nil
        isActive = false
        layer?.contents = nil
    }

    private func startTimerIfAnimated() {
        timer?.invalidate()
        guard frames.count > 1 else { return }
        let t = Timer(timeInterval: frameDelay, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.frames.isEmpty else { return }
                // Skip frame swaps while the window is hidden/occluded — no visible benefit,
                // and a grid of animating cells would otherwise burn CPU in the background.
                if let win = self.window, !win.occlusionState.contains(.visible) { return }
                self.frameIndex = (self.frameIndex + 1) % self.frames.count
                self.layer?.contents = self.frames[self.frameIndex]
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Decode downsampled frames off the main thread. Strides long animations down to
    /// `maxFrames`, scaling the per-frame delay so overall speed is preserved.
    private nonisolated static func decodeFrames(data: Data, maxPixelSize: CGFloat) -> (frames: [CGImage], delay: TimeInterval) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return ([], 0) }
        let total = CGImageSourceGetCount(src)
        guard total > 0 else { return ([], 0) }

        var delay: TimeInterval = 1.0 / 24.0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let webp = props["{WebP}" as CFString] as? [CFString: Any],
           let d = webp[kCGImagePropertyWebPDelayTime] as? Double, d > 0.005 {
            delay = d
        }

        let stride = max(1, Int((Double(total) / Double(maxFrames)).rounded(.up)))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        var frames: [CGImage] = []
        var i = 0
        while i < total {
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                frames.append(cg)
            }
            i += stride
        }
        return (frames, delay * Double(stride))
    }

    /// Decode a single still (the static-thumbnail fallback) downsampled to thumbnail size.
    private nonisolated static func decodeStill(data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Tiny async semaphore: caps how many decode jobs run at once. A released slot is handed
/// directly to the next waiter, so throughput stays at exactly `limit`.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume() // slot transfers to the next waiter
        }
    }
}
