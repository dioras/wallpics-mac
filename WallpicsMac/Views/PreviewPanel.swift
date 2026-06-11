import SwiftUI
import AVFoundation

/// One4Wall-style full-bleed featured hero: the selected wallpaper IS the preview, drawn
/// edge-to-edge with the title + Set Wallpaper overlaid. Replaces the old side panel (and its
/// long descriptions) so the artwork gets the whole window.
struct FeaturedHero: View {
    let wallpaper: Wallpaper?
    var bottomInset: CGFloat = 0
    @Environment(AppEnvironment.self) private var env
    @Environment(StoreKitService.self) private var store
    @Environment(FavoritesViewModel.self) private var favorites
    @State private var isSetting = false
    @State private var progress: Double = 0
    @State private var resultMessage: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Artwork, full bleed. Crossfades when the featured wallpaper changes.
            Group {
                if let wallpaper {
                    ZStack {
                        ThumbnailView(
                            url: wallpaper.thumbnailURL,
                            placeholderTint: WallpaperCard.tint(for: wallpaper.id)
                        )
                        if wallpaper.mediaType == .live, let video = wallpaper.assetURL {
                            HeroVideoPlayer(url: video)
                        }
                    }
                    .id(wallpaper.id)
                    .transition(.opacity)
                } else {
                    Rectangle().fill(.black.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Legibility scrims: dark feather at the bottom for the title block, and a faint
            // top wash so the floating nav stays readable over bright skies.
            LinearGradient(colors: [.black.opacity(0.78), .black.opacity(0.25), .clear, .clear],
                           startPoint: .bottom, endPoint: .top)
            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .top)

            if let wallpaper {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(verbatim: "FEATURED")
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(2.2)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(wallpaper.name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

                    HStack(spacing: Theme.Space.m) {
                        Button(action: { Task { await setAsWallpaper(wallpaper) } }) {
                            HStack(spacing: 7) {
                                if isSetting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "macwindow.on.rectangle")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text(isSetting ? String(localized: "Setting…") : String(localized: "Set Wallpaper"))
                                    .font(.callout.weight(.semibold))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .foregroundStyle(.black)
                            .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSetting)

                        let fav = favorites.isFavorite(wallpaper)
                        Button {
                            Task { await favorites.toggle(wallpaper) }
                        } label: {
                            Image(systemName: fav ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(fav ? AnyShapeStyle(.red) : AnyShapeStyle(.white))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.16), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                                .symbolEffectBounce(value: fav)
                                .animation(Motion.reward, value: fav)
                        }
                        .buttonStyle(.plain)

                        if let message = resultMessage {
                            Text(message)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .transition(.opacity)
                        } else if !store.state.isPro {
                            Button { PaywallPresenter.show() } label: {
                                Text("Free includes a small watermark — remove")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(Theme.Space.xxl)
                .padding(.bottom, bottomInset)
            }
        }
        .animation(Motion.transition, value: wallpaper?.id)
    }

    private func setAsWallpaper(_ wallpaper: Wallpaper) async {
        isSetting = true
        resultMessage = nil
        progress = 0
        defer { isSetting = false }

        let didSet: Bool
        // User-imported wallpaper: the asset is already on disk (file://), no download needed.
        if wallpaper.isLocal, let url = wallpaper.wallpaperURL, url.isFileURL {
            didSet = await setLocalWallpaper(wallpaper, assetURL: url)
        } else if let assetURL = wallpaper.assetURL {
            switch wallpaper.mediaType {
            case .photo:  didSet = await setRemoteImage(wallpaper, imageURL: assetURL)
            case .live:   didSet = await setRemoteAnimated(wallpaper, kind: .video, assetURL: assetURL)
            case .shader: didSet = await setRemoteShader(wallpaper, zipURL: assetURL)
            }
        } else {
            resultMessage = String(localized: "This wallpaper isn't available right now.")
            didSet = false
        }

        if didSet { maybeOfferAutostart() }
    }

    /// Static image: download, bake the watermark for free users, set as the desktop image.
    @discardableResult
    private func setRemoteImage(_ wallpaper: Wallpaper, imageURL: URL) async -> Bool {
        do {
            let downloaded = try await WallpaperAPI.shared.downloadImage(from: imageURL) { p in
                Task { @MainActor in progress = p }
            }
            // Filename varies by watermark state so a Pro upgrade produces a new URL and
            // macOS actually refreshes the desktop instead of reusing the cached image.
            let variant = store.state.isPro ? "pro" : "free"
            await CacheManager.shared.removeCachedImages(for: wallpaper.id)
            let destination = await CacheManager.shared.folderURL(.images)
                .appendingPathComponent("\(wallpaper.id)-\(variant).jpg")
            try WatermarkService.applyIfNeeded(
                to: downloaded,
                destinationURL: destination,
                isPro: store.state.isPro,
                appIcon: NSApplication.shared.applicationIconImage,
                screenAspects: NSScreen.screens.map { $0.frame.width / max(1, $0.frame.height) }
            )
            // Pin before setting the desktop image so a concurrent cache sweep can't delete it.
            await CacheManager.shared.markDownloaded(wallpaper.id, downloaded: true)
            WallpaperRenderer.shared.setStaticImage(destination)
            await WallpaperAPI.shared.recordDownload(wallpaperID: wallpaper.id)
            resultMessage = String(localized: "Wallpaper set.")
            return true
        } catch {
            resultMessage = error.localizedDescription
            Log.ui.error("Set failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Live (video) wallpaper: download the clip, play it through the live engine with the
    /// mandatory free-tier watermark overlay (dropped only once the user is Pro).
    @discardableResult
    private func setRemoteAnimated(_ wallpaper: Wallpaper, kind: WallpaperRenderer.Kind, assetURL: URL) async -> Bool {
        let isPro = store.state.isPro
        let icon = NSApplication.shared.applicationIconImage
        do {
            let downloaded = try await WallpaperAPI.shared.downloadImage(from: assetURL) { p in
                Task { @MainActor in progress = p }
            }
            let ext = assetURL.pathExtension.isEmpty ? "mp4" : assetURL.pathExtension
            let dest = await CacheManager.shared.folderURL(.videos)
                .appendingPathComponent("\(wallpaper.id).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: downloaded, to: dest)

            // Full-resolution first frame extracted from the 4K video — NOT the tiny thumbnail —
            // so the still shown the instant playback stops/relaunches isn't a pixelated 300px poster.
            var firstFrame = await makeVideoPoster(dest, id: wallpaper.id, isPro: isPro, icon: icon)
            if firstFrame == nil {
                firstFrame = await makeRemotePoster(wallpaper, isPro: isPro, icon: icon)
            }
            // Pin so the cache sweep can't evict the clip / first-frame while it's live.
            await CacheManager.shared.markDownloaded(wallpaper.id, downloaded: true)
            WallpaperRenderer.shared.startAnimated(kind: kind, url: dest,
                                                   firstFrameStaticURL: firstFrame,
                                                   needsWatermark: !isPro, appIcon: icon)
            await WallpaperAPI.shared.recordDownload(wallpaperID: wallpaper.id)
            resultMessage = String(localized: "Wallpaper set.")
            return true
        } catch {
            resultMessage = error.localizedDescription
            Log.ui.error("Live set failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Shader wallpaper: the backend ships a .zip containing a single .msl; unzip it, then drive
    /// the Metal shader engine (same free-tier watermark rules as live wallpapers).
    @discardableResult
    private func setRemoteShader(_ wallpaper: Wallpaper, zipURL: URL) async -> Bool {
        let isPro = store.state.isPro
        let icon = NSApplication.shared.applicationIconImage
        do {
            let downloaded = try await WallpaperAPI.shared.downloadImage(from: zipURL) { p in
                Task { @MainActor in progress = p }
            }
            let zipData = try Data(contentsOf: downloaded)
            let shadersDir = await CacheManager.shared.folderURL(.shaders)
            guard let shaderURL = ZipExtractor.extractFirstFile(
                from: zipData, extensions: ["msl", "metal"], to: shadersDir, baseName: "\(wallpaper.id)"
            ) else {
                resultMessage = String(localized: "Couldn't read this shader.")
                return false
            }
            // Render a full-resolution still of the shader itself for the desktop image — this is
            // what shows on the lock/login screen and when the app isn't running, where the live
            // Metal view can't draw. Falls back to the thumbnail only if the offscreen render fails.
            let shaderSource = (try? String(contentsOf: shaderURL, encoding: .utf8)) ?? ""
            var firstFrame = await makeShaderPoster(shaderSource: shaderSource, id: wallpaper.id, isPro: isPro, icon: icon)
            if firstFrame == nil {
                firstFrame = await makeRemotePoster(wallpaper, isPro: isPro, icon: icon)
            }
            await CacheManager.shared.markDownloaded(wallpaper.id, downloaded: true)
            WallpaperRenderer.shared.startAnimated(kind: .shader, url: shaderURL,
                                                   firstFrameStaticURL: firstFrame,
                                                   needsWatermark: !isPro, appIcon: icon)
            await WallpaperAPI.shared.recordDownload(wallpaperID: wallpaper.id)
            resultMessage = String(localized: "Wallpaper set.")
            return true
        } catch {
            resultMessage = error.localizedDescription
            Log.ui.error("Shader set failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Poster from a video's first frame — composited at the display's backing resolution so it's
    /// a pixel-faithful freeze-frame of the live wallpaper (used on the lock/login screen).
    private func makeVideoPoster(_ videoURL: URL, id: Int, isPro: Bool, icon: NSImage?) async -> URL? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else { return nil }
        return await writePoster(cg, id: id, isPro: isPro, icon: icon)
    }

    /// Poster from a shader, rendered offscreen at the display's backing resolution — so on the
    /// lock screen it looks exactly like the live shader, just paused.
    private func makeShaderPoster(shaderSource: String, id: Int, isPro: Bool, icon: NSImage?) async -> URL? {
        guard !shaderSource.isEmpty,
              let cg = ShaderSnapshot.render(shaderSource: shaderSource, pixelSize: posterTarget().size)
        else { return nil }
        return await writePoster(cg, id: id, isPro: isPro, icon: icon)
    }

    /// Fallback poster from the remote thumbnail when a frame/shader render isn't available.
    private func makeRemotePoster(_ wallpaper: Wallpaper, isPro: Bool, icon: NSImage?) async -> URL? {
        guard let posterURL = wallpaper.posterURL,
              let file = try? await WallpaperAPI.shared.downloadImage(from: posterURL),
              let cg = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return await writePoster(cg, id: wallpaper.id, isPro: isPro, icon: icon)
    }

    /// Compose `content` into a display-resolution, watermark-matched, lossless PNG desktop poster.
    private func writePoster(_ content: CGImage, id: Int, isPro: Bool, icon: NSImage?) async -> URL? {
        let target = posterTarget()
        let folder = await CacheManager.shared.folderURL(.firstFrames)
        // Drop any legacy JPEG poster for this id so we don't keep both around.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id).jpg"))
        let dest = folder.appendingPathComponent("\(id).png")
        let ok = WallpaperPoster.write(content: content, targetSize: target.size, scale: target.scale,
                                       isPro: isPro, appIcon: icon, to: dest)
        return ok ? dest : nil
    }

    /// The largest connected display's backing pixel size and its scale (pixels per point). The
    /// poster is built at this resolution so it matches what's actually shown on screen.
    private func posterTarget() -> (size: CGSize, scale: CGFloat) {
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

    /// Apply a user-imported wallpaper. Images are watermarked + set as the static desktop;
    /// animated formats play through the live engine with a mandatory watermark overlay (free).
    @discardableResult
    private func setLocalWallpaper(_ wallpaper: Wallpaper, assetURL: URL) async -> Bool {
        let isPro = store.state.isPro
        let icon = NSApplication.shared.applicationIconImage
        let aspects = NSScreen.screens.map { $0.frame.width / max(1, $0.frame.height) }
        let kind = WallpaperRenderer.Kind.detect(from: assetURL) ?? .image
        do {
            if kind == .image {
                let variant = isPro ? "pro" : "free"
                await CacheManager.shared.removeCachedImages(for: wallpaper.id)
                let destination = await CacheManager.shared.folderURL(.images)
                    .appendingPathComponent("\(wallpaper.id)-\(variant).jpg")
                try WatermarkService.applyIfNeeded(to: assetURL, destinationURL: destination,
                                                   isPro: isPro, appIcon: icon, screenAspects: aspects)
                await CacheManager.shared.markDownloaded(wallpaper.id, downloaded: true)
                WallpaperRenderer.shared.setStaticImage(destination)
            } else {
                // Display-resolution first frame from the video/shader when possible; thumbnail only
                // as a fallback. Same poster pipeline as remote wallpapers (matched watermark, PNG).
                var firstFrame: URL? = nil
                if kind == .video {
                    firstFrame = await makeVideoPoster(assetURL, id: wallpaper.id, isPro: isPro, icon: icon)
                } else if kind == .shader {
                    let source = (try? String(contentsOf: assetURL, encoding: .utf8)) ?? ""
                    firstFrame = await makeShaderPoster(shaderSource: source, id: wallpaper.id, isPro: isPro, icon: icon)
                }
                if firstFrame == nil, let thumb = wallpaper.thumbnailURL, thumb.isFileURL,
                   let cg = NSImage(contentsOf: thumb)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    firstFrame = await writePoster(cg, id: wallpaper.id, isPro: isPro, icon: icon)
                }
                // Pin so the cache sweep can't evict the first-frame fallback while it's active.
                await CacheManager.shared.markDownloaded(wallpaper.id, downloaded: true)
                WallpaperRenderer.shared.startAnimated(kind: kind, url: assetURL,
                                                       firstFrameStaticURL: firstFrame,
                                                       needsWatermark: !isPro, appIcon: icon)
            }
            resultMessage = String(localized: "Wallpaper set.")
            return true
        } catch {
            resultMessage = error.localizedDescription
            Log.ui.error("Local set failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// After the user sets their first wallpaper from the app (NOT onboarding — that uses a
    /// different code path), offer once to add WallPics to Login Items so live wallpapers survive
    /// a restart. We record that we asked and never nag again, even if they decline.
    private func maybeOfferAutostart() {
        guard !env.settings.didAskAutostart else { return }
        env.settings.didAskAutostart = true          // ask exactly once, ever
        if LoginItemService.isEnabled { return }     // already enabled → nothing to ask
        env.showAutostartPrompt = true
    }
}

struct HeroVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> HeroVideoView { HeroVideoView() }

    func updateNSView(_ view: HeroVideoView, context: Context) {
        view.play(url: url)
    }

    static func dismantleNSView(_ view: HeroVideoView, coordinator: ()) {
        view.stop()
    }
}

final class HeroVideoView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func play(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        teardownPlayer()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        playerLayer.player = queue
        queue.play()
        player = queue
    }

    func stop() {
        teardownPlayer()
        currentURL = nil
    }

    private func teardownPlayer() {
        player?.pause()
        looper = nil
        playerLayer.player = nil
        player = nil
    }
}

