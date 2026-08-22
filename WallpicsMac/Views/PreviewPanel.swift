import SwiftUI
import AVFoundation
import MetalKit

/// One4Wall-style full-bleed featured hero: the selected wallpaper IS the preview, drawn
/// edge-to-edge with the title + Set Wallpaper overlaid. Replaces the old side panel (and its
/// long descriptions) so the artwork gets the whole window.
struct FeaturedHero: View {
    let wallpaper: Wallpaper?
    var bottomInset: CGFloat = 0
    @Environment(AppEnvironment.self) private var env
    @Environment(StoreKitService.self) private var store
    @Environment(FavoritesViewModel.self) private var favorites
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSetting = false
    @State private var progress: Double = 0
    @State private var resultMessage: String?
    @State private var heroVideoURL: URL?
    @State private var heroShaderURL: URL?
    @State private var heroImage: NSImage?
    @State private var loadProgress: Double = 0
    @State private var showFullLoader = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Artwork, full bleed. The poster shows instantly; for live wallpapers the FULL
            // video is downloaded to the cache first and only then plays — no mid-stream
            // stutter or low-quality first seconds. Re-set wallpapers reuse the same file.
            Group {
                if let wallpaper {
                    ZStack {
                        ThumbnailView(
                            url: wallpaper.thumbnailURL,
                            placeholderTint: WallpaperCard.tint(for: wallpaper.id)
                        )
                        if let heroImage {
                            GeometryReader { geo in
                                Image(nsImage: heroImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                            }
                            .transition(.opacity)
                        }
                        if let heroVideoURL {
                            HeroVideoPlayer(url: heroVideoURL)
                                .transition(.opacity)
                        }
                        if let heroShaderURL {
                            HeroShaderPlayer(url: heroShaderURL)
                                .transition(.opacity)
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
            .task(id: wallpaper?.id) { await loadFullAsset() }

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
                    if showFullLoader {
                        HeroLoadingBar(progress: loadProgress)
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                            .padding(.bottom, 2)
                    }
                    Text(verbatim: "FEATURED")
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(2.2)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(wallpaper.name)
                        .font(.system(size: 24, weight: .bold))
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
                            Image(systemName: fav ? "star.fill" : "star")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(fav ? AnyShapeStyle(.yellow) : AnyShapeStyle(.white))
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
                                HStack(spacing: 6) {
                                    Image(systemName: "seal")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Remove watermark")
                                        .font(.callout.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
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

    // MARK: - Full-resolution preview prefetch

    private func loadFullAsset() async {
        heroImage = nil
        heroVideoURL = nil
        heroShaderURL = nil
        loadProgress = 0
        showFullLoader = false
        guard let wallpaper else { return }
        switch wallpaper.mediaType {
        case .photo:  await loadFullImage(wallpaper)
        case .live:   await loadFullVideo(wallpaper)
        case .shader: await loadFullShader(wallpaper)
        }
    }

    private func loadFullImage(_ wallpaper: Wallpaper) async {
        guard let remote = wallpaper.wallpaperURL else { return }
        if remote.isFileURL {
            if let img = try? await ImageLoader.shared.image(for: remote, maxPixelSize: heroPixelTarget()),
               sameWallpaper(wallpaper) {
                withAnimation(.easeIn(duration: 0.3)) { heroImage = img }
            }
            return
        }
        let ext = remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension
        let local = await CacheManager.shared.folderURL(.images)
            .appendingPathComponent("\(wallpaper.id)-full.\(ext)")
        if FileManager.default.fileExists(atPath: local.path) {
            if let img = try? await ImageLoader.shared.image(for: local, maxPixelSize: heroPixelTarget()),
               sameWallpaper(wallpaper) {
                withAnimation(.easeIn(duration: 0.3)) { heroImage = img }
            }
            return
        }
        beginLoader()
        do {
            let tmp = try await WallpaperAPI.shared.downloadImage(from: remote) { [wid = wallpaper.id] p in
                Task { @MainActor in if self.wallpaper?.id == wid { loadProgress = p } }
            }
            try? FileManager.default.removeItem(at: local)
            do { try FileManager.default.moveItem(at: tmp, to: local) }
            catch { Log.ui.error("Hero cache move failed: \(error.localizedDescription, privacy: .public)") }
            guard sameWallpaper(wallpaper),
                  let img = try? await ImageLoader.shared.image(for: local, maxPixelSize: heroPixelTarget()),
                  sameWallpaper(wallpaper)
            else { endLoader(); return }
            await completeLoader { withAnimation(.easeIn(duration: 0.35)) { heroImage = img } }
        } catch {
            endLoader()
        }
    }

    private func loadFullVideo(_ wallpaper: Wallpaper) async {
        guard let remote = wallpaper.assetURL else { return }
        if remote.isFileURL {
            heroVideoURL = remote
            return
        }
        let ext = remote.pathExtension.isEmpty ? "mp4" : remote.pathExtension
        let local = await CacheManager.shared.folderURL(.videos)
            .appendingPathComponent("\(wallpaper.id).\(ext)")
        if FileManager.default.fileExists(atPath: local.path) {
            guard sameWallpaper(wallpaper) else { return }
            withAnimation(.easeIn(duration: 0.3)) { heroVideoURL = local }
            return
        }
        beginLoader()
        do {
            let tmp = try await WallpaperAPI.shared.downloadImage(from: remote) { [wid = wallpaper.id] p in
                Task { @MainActor in if self.wallpaper?.id == wid { loadProgress = p } }
            }
            try? FileManager.default.removeItem(at: local)
            do { try FileManager.default.moveItem(at: tmp, to: local) }
            catch { Log.ui.error("Hero cache move failed: \(error.localizedDescription, privacy: .public)") }
            guard sameWallpaper(wallpaper), FileManager.default.fileExists(atPath: local.path)
            else { endLoader(); return }
            await completeLoader { withAnimation(.easeIn(duration: 0.35)) { heroVideoURL = local } }
        } catch {
            endLoader()
        }
    }

    private func loadFullShader(_ wallpaper: Wallpaper) async {
        guard let remote = wallpaper.assetURL else { return }
        let shadersDir = await CacheManager.shared.folderURL(.shaders)
        // Already-extracted shader source on disk → play it live, no download.
        for ext in ["msl", "metal"] {
            let local = shadersDir.appendingPathComponent("\(wallpaper.id).\(ext)")
            if FileManager.default.fileExists(atPath: local.path), sameWallpaper(wallpaper) {
                withAnimation(.easeIn(duration: 0.3)) { heroShaderURL = local }
                return
            }
        }
        if remote.isFileURL {
            guard sameWallpaper(wallpaper) else { return }
            withAnimation(.easeIn(duration: 0.3)) { heroShaderURL = remote }
            return
        }
        beginLoader()
        do {
            let tmp = try await WallpaperAPI.shared.downloadImage(from: remote) { [wid = wallpaper.id] p in
                Task { @MainActor in if self.wallpaper?.id == wid { loadProgress = p } }
            }
            let zipData = try Data(contentsOf: tmp)
            guard let shaderURL = ZipExtractor.extractFirstFile(
                from: zipData, extensions: ["msl", "metal"], to: shadersDir, baseName: "\(wallpaper.id)"
            ), sameWallpaper(wallpaper) else { endLoader(); return }
            await completeLoader { withAnimation(.easeIn(duration: 0.35)) { heroShaderURL = shaderURL } }
        } catch {
            Log.ui.error("Hero shader load failed: \(error.localizedDescription, privacy: .public)")
            endLoader()
        }
    }

    private func sameWallpaper(_ candidate: Wallpaper) -> Bool {
        !Task.isCancelled && wallpaper?.id == candidate.id
    }

    private func beginLoader() {
        withAnimation(reduceMotion ? .easeIn(duration: 0.12) : Motion.hover) { showFullLoader = true }
    }

    private func endLoader() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : Motion.hover) { showFullLoader = false }
    }

    /// Fill the bar to 100%, swap in the full-quality content, then dismiss the bar with a
    /// quick settle so the user sees the load complete before it disappears.
    private func completeLoader(_ revealContent: () -> Void) async {
        withAnimation(.easeOut(duration: 0.2)) { loadProgress = 1 }
        revealContent()
        try? await Task.sleep(for: .milliseconds(280))
        endLoader()
    }

    private func heroPixelTarget() -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = (NSScreen.main?.frame.width ?? 1920) * scale
        return Int(min(2560, max(1280, width)))
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

/// Slim, unobtrusive indicator shown over the hero while the full-resolution asset downloads,
/// telling the user the first preview isn't final quality. Fills to 100% then fades away.
private struct HeroLoadingBar: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private let trackWidth: CGFloat = 224
    private let barHeight: CGFloat = 5
    private let sweepWidth: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                    .shadow(color: .white.opacity(0.7), radius: 4)
                    .opacity(reduceMotion ? 1 : (animate ? 1 : 0.3))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                               value: animate)
                Text("Loading full quality")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(.white)
                    .frame(width: max(barHeight, trackWidth * progress))
                    .shadow(color: .white.opacity(0.6), radius: 5)
                    .animation(.easeOut(duration: 0.25), value: progress)
                if !reduceMotion {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.65), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: sweepWidth)
                        .offset(x: animate ? trackWidth : -sweepWidth)
                        .animation(.linear(duration: 1.15).repeatForever(autoreverses: false), value: animate)
                }
            }
            .frame(width: trackWidth, height: barHeight)
            .clipShape(Capsule())
        }
        .onAppear { animate = true }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading full quality"))
        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }
}

struct DetailOverlay: View {
    let wallpaper: Wallpaper
    let list: [Wallpaper]
    let onClose: () -> Void
    let onShow: (Wallpaper) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero
    @State private var axis: DragAxis?
    @State private var swipe = SwipeController()
    @State private var scrollMonitor: Any?

    private enum DragAxis { case horizontal, vertical }

    private var index: Int? { list.firstIndex(where: { $0.id == wallpaper.id }) }

    /// 0…1 as the user pulls down to dismiss; drives background dim + content shrink.
    private var dismissProgress: CGFloat {
        guard drag.height > 0 else { return 0 }
        return min(1, drag.height / 260)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dismissProgress * 0.6).ignoresSafeArea()

            ZStack {
                FeaturedHero(wallpaper: wallpaper)
                    .id(wallpaper.id)

                HStack {
                    arrow("chevron.left", enabled: previousWallpaper != nil) {
                        if let previousWallpaper { onShow(previousWallpaper) }
                    }
                    Spacer()
                    arrow("chevron.right", enabled: nextWallpaper != nil) {
                        if let nextWallpaper { onShow(nextWallpaper) }
                    }
                }
                .padding(.horizontal, Theme.Space.l)

                VStack {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.14), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                        Spacer()
                        if let index {
                            Text(verbatim: "\(index + 1) / \(list.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white.opacity(0.10), in: Capsule())
                        }
                    }
                    .padding(Theme.Space.l)
                    Spacer()
                }
            }
            .scaleEffect(reduceMotion ? 1 : 1 - dismissProgress * 0.08)
            .clipShape(RoundedRectangle(cornerRadius: dismissProgress > 0 ? Theme.Radius.hero : 0,
                                        style: .continuous))
            .offset(drag)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(slideGesture)
        .onAppear { configureSwipe(); addScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: wallpaper.id) { _, _ in
            drag = .zero
            axis = nil
            configureSwipe()
        }
        .onExitCommand(perform: onClose)
    }

    /// Two-finger trackpad swipes arrive as scrollWheel events (not mouse drags), so a
    /// SwiftUI DragGesture never sees them. A local scroll monitor handles them: horizontal
    /// → previous/next, downward → close. Same outcome as the on-screen arrows / close button.
    private func configureSwipe() {
        swipe.list = list
        swipe.currentID = wallpaper.id
        swipe.setOffset = { drag = $0 }
        swipe.snapBack = {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.hover) { drag = .zero }
        }
        swipe.onNext = { if let next = swipe.next { onShow(next) } }
        swipe.onPrevious = { if let previous = swipe.previous { onShow(previous) } }
        swipe.onCloseAction = onClose
    }

    private func addScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { swipe.handle(event) }
            return event.hasPreciseScrollingDeltas ? nil : event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// Slide left/right for previous/next and down to dismiss — an alternative to the on-screen
    /// arrows and close button. The first movement locks to the dominant axis so a horizontal
    /// flick never half-triggers a dismiss and vice-versa.
    private var slideGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                switch axis {
                case .horizontal:
                    var dx = value.translation.width
                    // Rubber-band when there's no neighbour in that direction.
                    if (dx > 0 && previousWallpaper == nil) || (dx < 0 && nextWallpaper == nil) { dx *= 0.25 }
                    drag = CGSize(width: dx, height: 0)
                case .vertical:
                    let dy = value.translation.height
                    drag = CGSize(width: 0, height: dy > 0 ? dy : dy * 0.25)
                case .none:
                    break
                }
            }
            .onEnded { value in
                let settle = reduceMotion ? Animation.easeOut(duration: 0.2) : Motion.hover
                let dx = value.translation.width
                let dy = value.translation.height
                switch axis {
                case .horizontal:
                    if dx <= -80, let next = nextWallpaper {
                        onShow(next)
                    } else if dx >= 80, let previous = previousWallpaper {
                        onShow(previous)
                    } else {
                        withAnimation(settle) { drag = .zero }
                    }
                case .vertical:
                    if dy >= 150 {
                        drag = .zero
                        onClose()
                    } else {
                        withAnimation(settle) { drag = .zero }
                    }
                case .none:
                    withAnimation(settle) { drag = .zero }
                }
                axis = nil
            }
    }

    private var previousWallpaper: Wallpaper? {
        guard let index, index > 0 else { return nil }
        return list[index - 1]
    }

    private var nextWallpaper: Wallpaper? {
        guard let index, index < list.count - 1 else { return nil }
        return list[index + 1]
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.25))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Turns two-finger trackpad scroll into discrete navigation: a decisive horizontal swipe
/// commits to the previous/next wallpaper, a downward swipe closes the viewer. The content
/// follows the fingers a little (via `setOffset`) and springs back if the swipe is too small.
@MainActor
final class SwipeController {
    var list: [Wallpaper] = []
    var currentID: Int?
    var setOffset: (CGSize) -> Void = { _ in }
    var snapBack: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onCloseAction: () -> Void = {}

    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0
    private var axis = 0           // 0 none, 1 horizontal, 2 vertical
    private var committed = false
    private let commitThreshold: CGFloat = 52

    private var index: Int? { list.firstIndex { $0.id == currentID } }
    var next: Wallpaper? { guard let i = index, i < list.count - 1 else { return nil }; return list[i + 1] }
    var previous: Wallpaper? { guard let i = index, i > 0 else { return nil }; return list[i - 1] }

    func handle(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        switch event.phase {
        case .began:
            reset()
        case .changed:
            guard !committed else { return }
            accumX += event.scrollingDeltaX
            accumY += event.scrollingDeltaY
            if axis == 0, max(abs(accumX), abs(accumY)) > 8 {
                axis = abs(accumX) > abs(accumY) ? 1 : 2
            }
            applyOffset()
            checkCommit()
        case .ended, .cancelled:
            if !committed { snapBack() }
            reset()
        default:
            break
        }
    }

    private func reset() {
        accumX = 0; accumY = 0; axis = 0; committed = false
    }

    private func applyOffset() {
        if axis == 1 {
            var dx = accumX
            if (dx > 0 && previous == nil) || (dx < 0 && next == nil) { dx *= 0.25 }
            setOffset(CGSize(width: dx, height: 0))
        } else if axis == 2 {
            setOffset(CGSize(width: 0, height: accumY > 0 ? accumY : accumY * 0.25))
        }
    }

    private func checkCommit() {
        if axis == 1 {
            if accumX <= -commitThreshold, next != nil { commit(onNext) }
            else if accumX >= commitThreshold, previous != nil { commit(onPrevious) }
        } else if axis == 2, accumY >= commitThreshold {
            commit(onCloseAction)
        }
    }

    private func commit(_ action: () -> Void) {
        committed = true
        setOffset(.zero)
        action()
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

    // Transparent to the mouse so the detail view's swipe gesture (and the browse scroll)
    // still receive drags that start over the playing video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

struct HeroShaderPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> HeroShaderView { HeroShaderView() }

    func updateNSView(_ view: HeroShaderView, context: Context) {
        view.play(url: url)
    }

    static func dismantleNSView(_ view: HeroShaderView, coordinator: ()) {
        view.stop()
    }
}

final class HeroShaderView: NSView {
    private var mtkView: MTKView?
    private var renderer: ShaderRenderer?
    private var currentURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    // Transparent to the mouse so the detail view's swipe gesture still receives drags
    // that start over the playing shader.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func play(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        stop()
        guard let device = MTLCreateSystemDefaultDevice(),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        let view = MTKView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        // Clear to transparent so a failed/empty shader compile reveals the thumbnail underneath
        // instead of a black rectangle.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        let renderer = ShaderRenderer(device: device, shaderSource: source)
        view.delegate = renderer
        self.renderer = renderer
        self.mtkView = view
        addSubview(view)
    }

    func stop() {
        mtkView?.removeFromSuperview()
        mtkView = nil
        renderer = nil
    }
}

