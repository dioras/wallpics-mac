import SwiftUI
import AVFoundation

struct PreviewPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(StoreKitService.self) private var store
    @Environment(FavoritesViewModel.self) private var favorites
    @State private var isSetting = false
    @State private var progress: Double = 0
    @State private var resultMessage: String?

    var body: some View {
        Group {
            if let wallpaper = env.selectedWallpaper {
                content(for: wallpaper)
            } else {
                EmptyPreview()
            }
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func content(for wallpaper: Wallpaper) -> some View {
        VStack(spacing: 0) {
            ThumbnailView(
                url: wallpaper.thumbnailURL,
                placeholderTint: WallpaperCard.tint(for: wallpaper.id)
            )
            .frame(height: 220)
            .clipped()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(wallpaper.name)
                                .font(.title3.weight(.semibold))
                            Text(String(localized: "by \(wallpaper.safeAuthor)"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let fav = favorites.isFavorite(wallpaper)
                        Button {
                            Task { await favorites.toggle(wallpaper) }
                        } label: {
                            Image(systemName: fav ? "star.fill" : "star")
                                .foregroundStyle(fav ? .yellow : .secondary)
                                .font(.title3)
                                .symbolEffectBounce(value: fav)
                                .scaleEffect(fav ? 1.1 : 1.0)
                                .animation(Motion.reward, value: fav)
                        }
                        .buttonStyle(.plain)
                    }

                    if !wallpaper.safeDescription.isEmpty {
                        Text(wallpaper.safeDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        InfoChip(label: String(localized: "Resolution"), value: "\(wallpaper.width)×\(wallpaper.height)")
                        InfoChip(label: String(localized: "Downloads"), value: wallpaper.safeDownloadCount.formatted())
                    }

                    if !wallpaper.safeTags.isEmpty {
                        WrappingTagList(tags: wallpaper.safeTags.map(\.name))
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }

            VStack(spacing: 10) {
                if let message = resultMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button(action: { Task { await setAsWallpaper(wallpaper) } }) {
                    HStack {
                        if isSetting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isSetting ? String(localized: "Setting…") : String(localized: "Set as Wallpaper"))
                    }
                }
                .buttonStyle(.primaryCTA)
                .disabled(isSetting)

                if !store.state.isPro {
                    HStack(spacing: 6) {
                        Image(systemName: "drop.degreesign")
                        Text("Free wallpapers include a small watermark.")
                        Button("Remove") { PaywallPresenter.show() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.l)
            .background(.regularMaterial)
        }
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

private struct EmptyPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Pick a wallpaper to preview it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct InfoChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
        }
    }
}

private struct WrappingTagList: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags.prefix(12), id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var (x, y, lineHeight): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var (x, y, lineHeight): (CGFloat, CGFloat, CGFloat) = (bounds.minX, bounds.minY, 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
