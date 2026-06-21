import SwiftUI

/// Faithful macOS render of every ported widget. This is the single source of truth used by the
/// gallery tiles, the editor live preview, and the desktop overlay. It's a pure function of
/// `(instance, isToggled)` — the caller owns the interactive flag so the same view drives a
/// preview tap and a real desktop click.
///
/// The themed bodies (elevator / opened-eyes / garage-door / windows-xp) port the exact layer
/// composition and `.easeOut(0.55)` slide geometry from the iOS `Small*View` renderers; the only
/// changes are `Image(uiImage:)` → `Image(nsImage:)` and dropping the WidgetKit-only modifiers
/// (`widgetAccentedRenderingMode`, `containerBackground(_:for:.widget)`, `Button(intent:)`).
struct WidgetRenderView: View {
    let instance: WidgetInstance
    /// Interactive state: `true` = closed/hidden (themed) or animating (DIY). Ignored by static kinds.
    var isToggled: Bool = false
    /// Carousel position for the polaroid (advances by 1 per click). Ignored by other kinds.
    var carouselStep: Int = 0

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width, height: geo.size.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }

    @ViewBuilder
    private func content(width w: CGFloat, height h: CGFloat) -> some View {
        switch instance.kind {
        case .photo:       PhotoBody(instance: instance, w: w, h: h)
        case .staticImage: StaticImageBody(instance: instance, w: w, h: h)
        case .polaroid:    PolaroidBody(instance: instance, step: carouselStep, w: w, h: h)
        case .elevator:    ElevatorBody(instance: instance, isClosed: isToggled, w: w, h: h)
        case .openedEyes:  OpenedEyesBody(instance: instance, isClosed: isToggled, w: w, h: h)
        case .garageDoor:  GarageDoorBody(instance: instance, isClosed: isToggled, w: w, h: h)
        case .windowsXP:   WindowsXPBody(instance: instance, isHidden: isToggled, w: w, h: h)
        case .diyAnimated: DIYAnimatedBody(instance: instance, isAnimating: isToggled, w: w, h: h)
        case .template:    TemplateBody(instance: instance, w: w, h: h)
        }
    }
}

// MARK: - Image resolution helpers

enum WidgetRenderAssets {
    @MainActor
    static func userImage(_ relativePath: String?, in id: UUID, maxPixelSize: Int = 640) -> NSImage? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let url = WidgetStore.shared.assetURL(for: relativePath, in: id)
        return WidgetImage.load(at: url, maxPixelSize: maxPixelSize)
    }

    @MainActor
    static func themeImage(slug: String, name: String, maxPixelSize: Int = 640) -> NSImage? {
        guard let url = WidgetAssetResolver.url(forResource: name, withExtension: "png", slug: slug) else {
            return nil
        }
        return WidgetImage.load(at: url, maxPixelSize: maxPixelSize)
    }
}

/// A resizable, fill-cropped NSImage layer — the cross-platform stand-in for the iOS
/// `Image(uiImage:).resizable().scaledToFill()` pattern used throughout the widget renderers.
private struct ImageLayer: View {
    let image: NSImage?
    var fill: Bool = true
    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: fill ? .fill : .fit)
        }
    }
}

// MARK: - Photo

private struct PhotoBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let state = photoState
        let image = WidgetRenderAssets.userImage(state.relativePaths.first, in: instance.id, maxPixelSize: 900)
        ZStack {
            Color.black.opacity(0.25)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: state.fill ? .fill : .fit)
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                placeholder
            }
        }
        .frame(width: w, height: h)
    }

    private var photoState: PhotoWidgetState {
        if case .photo(let s) = instance.payload { return s }
        return PhotoWidgetState()
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: min(w, h) * 0.22))
            Text("Add photo").font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Static image (NEW)

private struct StaticImageBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let image = WidgetRenderAssets.userImage(instance.payload.staticImagePath, in: instance.id, maxPixelSize: 900)
        ZStack {
            Color.black.opacity(0.15)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                Image(systemName: "photo.artframe")
                    .font(.system(size: min(w, h) * 0.22))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Elevator (ports SmallElevatorView)

private struct ElevatorBody: View {
    let instance: WidgetInstance
    let isClosed: Bool
    let w: CGFloat
    let h: CGFloat

    private let slug = "elevator"
    private let closedScale: CGFloat = 0.85

    var body: some View {
        let photo = WidgetRenderAssets.userImage(instance.payload.themedPhotoPath, in: instance.id)
            ?? WidgetRenderAssets.themeImage(slug: slug, name: "frame3")
        ZStack {
            // backdrop (frame4)
            if let bg = WidgetRenderAssets.themeImage(slug: slug, name: "frame4") {
                ImageLayer(image: bg).frame(width: w, height: h).clipped()
            } else {
                Color(red: 0.18, green: 0.18, blue: 0.18)
            }
            // photo (scales down when closed)
            ImageLayer(image: photo).frame(width: w, height: h).clipped()
                .scaleEffect(isClosed ? closedScale : 1.0)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            // left door (frame1) slides off left when open
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h)
                .offset(x: isClosed ? 0 : -w)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            // right door (frame2) slides off right when open
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame2"))
                .frame(width: w, height: h)
                .offset(x: isClosed ? 0 : w)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            // casing (frame5) on top so doors slide behind the side walls
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame5"))
                .frame(width: w, height: h).clipped()
                .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

// MARK: - Opened Eyes (ports SmallOpenedEyesView)

private struct OpenedEyesBody: View {
    let instance: WidgetInstance
    let isClosed: Bool
    let w: CGFloat
    let h: CGFloat

    private let slug = "opened_eyes"
    private let openSlide: CGFloat = 0.25

    var body: some View {
        let slide = h * openSlide
        let photo = WidgetRenderAssets.userImage(instance.payload.themedPhotoPath, in: instance.id)
            ?? WidgetRenderAssets.themeImage(slug: slug, name: "photo1")
        ZStack {
            Color.black
            ImageLayer(image: photo).frame(width: w, height: h).clipped()
            // top eyelid (frame1) aligned top, slides up to open
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h, alignment: .top)
                .offset(y: isClosed ? 0 : -slide)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            // bottom eyelid (frame2) aligned bottom, slides down to open
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame2"))
                .frame(width: w, height: h, alignment: .bottom)
                .offset(y: isClosed ? 0 : slide)
                .animation(.easeOut(duration: 0.55), value: isClosed)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

// MARK: - Garage Door (ports SmallGarageDoorView)

private struct GarageDoorBody: View {
    let instance: WidgetInstance
    let isClosed: Bool
    let w: CGFloat
    let h: CGFloat

    private let slug = "garage_door"

    var body: some View {
        let photo = WidgetRenderAssets.userImage(instance.payload.themedPhotoPath, in: instance.id)
            ?? WidgetRenderAssets.themeImage(slug: slug, name: "photo1")
        ZStack {
            Color.black.opacity(0.6)
            ImageLayer(image: photo).frame(width: w, height: h).clipped()
            // door (frame1): closed y=0 covers photo; open y=-h slid up off the top
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h).clipped()
                .offset(y: isClosed ? 0 : -h)
                .animation(.easeOut(duration: 0.55), value: isClosed)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

// MARK: - Windows XP (ports SmallWindowsXPView)

private struct WindowsXPBody: View {
    let instance: WidgetInstance
    let isHidden: Bool
    let w: CGFloat
    let h: CGFloat

    private let slug = "windows_xp"
    private let photoRestingOffset: CGFloat = 0.07
    private let hideSlide: CGFloat = 0.6

    var body: some View {
        let visibleY = h * photoRestingOffset
        let hiddenY = h * (photoRestingOffset + hideSlide)
        let photo = WidgetRenderAssets.userImage(instance.payload.themedPhotoPath, in: instance.id)
            ?? WidgetRenderAssets.themeImage(slug: slug, name: "frame2")
        ZStack {
            // backdrop (frame3)
            if let bg = WidgetRenderAssets.themeImage(slug: slug, name: "frame3") {
                ImageLayer(image: bg).frame(width: w, height: h).clipped()
            } else {
                Color(red: 0.30, green: 0.55, blue: 0.85)
            }
            // photo slides behind the hill when hidden
            ImageLayer(image: photo).frame(width: w, height: h).clipped()
                .offset(y: isHidden ? hiddenY : visibleY)
                .animation(.easeOut(duration: 0.55), value: isHidden)
            // foreground hill (frame1)
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h).clipped()
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

// MARK: - DIY Animated (ports SmallDIYAnimatedView)

private struct DIYAnimatedBody: View {
    let instance: WidgetInstance
    let isAnimating: Bool
    let w: CGFloat
    let h: CGFloat

    @State private var frameIndex = 0
    // Resolved once when the widget appears (or its photo set changes), not on every 12fps tick —
    // re-decoding per tick churns the cache and can flash if a frame gets evicted mid-animation.
    @State private var frames: [NSImage] = []
    @State private var cover: NSImage?
    private let timer = Timer.publish(every: 1.0 / 12.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.white
            content
        }
        .frame(width: w, height: h)
        .task(id: frameKey) { loadAssets() }
        .onReceive(timer) { _ in
            guard isAnimating, !frames.isEmpty else { return }
            frameIndex = (frameIndex + 1) % frames.count
        }
    }

    @ViewBuilder
    private var content: some View {
        if isAnimating, !frames.isEmpty {
            let safeIndex = min(frameIndex, frames.count - 1)
            ImageLayer(image: frames[safeIndex]).frame(width: w, height: h).clipped()
        } else if let cover {
            ImageLayer(image: cover).frame(width: w, height: h).clipped()
        } else {
            Image(systemName: "wand.and.stars")
                .font(.system(size: min(w, h) * 0.2))
                .foregroundStyle(.secondary)
        }
    }

    private var diyState: DIYAnimatedWidgetState {
        if case .diyAnimated(let s) = instance.payload { return s }
        return DIYAnimatedWidgetState()
    }

    /// Identity for the asset load: re-run only when the instance or its frame set changes.
    private var frameKey: String {
        instance.id.uuidString + "|" + diyState.bakedFrameRelativePaths.joined(separator: ",")
    }

    @MainActor
    private func loadAssets() {
        let s = diyState
        cover = WidgetRenderAssets.userImage(s.coverRelativePath ?? s.photoRelativePath, in: instance.id)
        frames = s.bakedFrameRelativePaths.compactMap {
            WidgetRenderAssets.userImage($0, in: instance.id)
        }
        frameIndex = 0
    }
}

// MARK: - Polaroid (click-advance carousel, ported from SmallPolaroidCarouselView)

private struct PolaroidBody: View {
    let instance: WidgetInstance
    /// Carousel position. The photo at `step` is the front card; clicking advances it.
    let step: Int
    let w: CGFloat
    let h: CGFloat

    /// Transform for a card given its slot distance from the front (0 = front). Each photo keeps a
    /// stable identity and animates between slots, so advancing slides the front card off to the
    /// left while the next card rises to the front — the iOS shuffle, not a cross-fade.
    private struct Slot { var offset: CGSize; var rotation: Double; var scale: CGFloat; var opacity: Double; var z: Double }

    var body: some View {
        let state = polaroidState
        let images = state.relativePaths.compactMap {
            WidgetRenderAssets.userImage($0, in: instance.id, maxPixelSize: 600)
        }
        let count = images.count
        ZStack {
            background(state.background)
            if count == 0 {
                Image(systemName: "photo.stack")
                    .font(.system(size: min(w, h) * 0.2))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(0..<count, id: \.self) { index in
                    let slotDistance = ((index - step) % count + count) % count
                    let s = slot(distance: slotDistance, count: count)
                    polaroidCard(images[index])
                        .rotationEffect(.degrees(s.rotation))
                        .scaleEffect(s.scale)
                        .offset(s.offset)
                        .opacity(s.opacity)
                        .zIndex(s.z)
                }
            }
        }
        .frame(width: w, height: h)
        .animation(.smooth(duration: 0.55), value: step)
    }

    private func slot(distance: Int, count: Int) -> Slot {
        // The card that just left the front (largest distance, when there are ≥3) flies off-left.
        if count >= 3 && distance == count - 1 {
            return Slot(offset: CGSize(width: -w * 0.85, height: -6), rotation: -16, scale: 0.9, opacity: 0, z: 120)
        }
        switch distance {
        case 0:  return Slot(offset: .zero, rotation: -4, scale: 1.0, opacity: 1, z: 100)              // front
        case 1:  return Slot(offset: CGSize(width: w * 0.07, height: -h * 0.05), rotation: 6, scale: 0.93, opacity: 1, z: 90)  // peek behind
        case 2:  return Slot(offset: CGSize(width: -w * 0.06, height: h * 0.04), rotation: -8, scale: 0.88, opacity: 0.95, z: 80)
        default: return Slot(offset: .zero, rotation: 0, scale: 0.85, opacity: 0, z: 10)               // hidden in the deck
        }
    }

    /// A single polaroid card: photo in the upper area, white frame with a caption strip below.
    private func polaroidCard(_ image: NSImage) -> some View {
        let side = min(w, h) * 0.72
        return VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side * 0.86, height: side * 0.70)
                .clipped()
                .padding(.top, side * 0.07)
                .padding(.horizontal, side * 0.07)
            Spacer(minLength: 0)
        }
        .frame(width: side, height: side * 1.18)
        .background(Color.white)
        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
    }

    @ViewBuilder
    private func background(_ bg: PolaroidWidgetState.Background) -> some View {
        switch bg {
        case .transparent:
            Color.clear
        case .album(let relativePath):
            if let img = WidgetRenderAssets.userImage(relativePath, in: instance.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h).clipped().blur(radius: 8).overlay(Color.black.opacity(0.2))
            } else {
                Color.black.opacity(0.2)
            }
        case .color(let hexes):
            LinearGradient(colors: hexes.compactMap(Color.init(hex:)).ifEmpty([.gray]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var polaroidState: PolaroidWidgetState {
        if case .polaroid(let s) = instance.payload { return s }
        return PolaroidWidgetState()
    }
}

// MARK: - Template (backend Widgify preview)

private struct TemplateBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        // Prefer a local preview asset baked from the bundle; otherwise render the real catalog
        // thumbnail (covers Widgify templates and not-yet-supported kinds like `world_cup_stats`,
        // so they show their actual artwork rather than an empty box). ThumbnailView's URLCache
        // keeps it available offline after the first load.
        let localImage = WidgetRenderAssets.userImage(instance.payload.templatePreviewPath, in: instance.id, maxPixelSize: 900)
        ZStack {
            Color.black.opacity(0.15)
            if let localImage {
                Image(nsImage: localImage).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fill).frame(width: w, height: h).clipped()
            } else if let thumb = instance.payload.templateThumbnailURL {
                ThumbnailView(url: thumb, placeholderTint: .black.opacity(0.15))
                    .frame(width: w, height: h).clipped()
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: min(w, h) * 0.2))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Small helpers

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

extension Color {
    /// Hex string (`#RRGGBB` / `RRGGBBAA`) → Color, for polaroid background colours.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
