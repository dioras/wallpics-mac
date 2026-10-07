import SwiftUI
import AVFoundation
import CryptoKit

struct WidgetRenderView: View {
    let instance: WidgetInstance
    var isToggled: Bool = false
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
        case .video:       VideoBody(instance: instance, w: w, h: h)
        case .staticImage: StaticImageBody(instance: instance, w: w, h: h)
        case .polaroid:    PolaroidBody(instance: instance, step: carouselStep, w: w, h: h)
        case .elevator:    ElevatorBody(instance: instance, isClosed: isToggled, w: w, h: h)
        case .openedEyes:  OpenedEyesBody(instance: instance, isClosed: isToggled, w: w, h: h)
        case .garageDoor:  GarageDoorBody(instance: instance, isClosed: isToggled, w: w, h: h)
        case .windowsXP:   WindowsXPBody(instance: instance, isHidden: isToggled, w: w, h: h)
        case .diyAnimated: DIYAnimatedBody(instance: instance, isAnimating: isToggled, w: w, h: h)
        case .template:    TemplateBody(instance: instance, w: w, h: h)
        case .dateTime:    DateTimeBody(instance: instance, w: w, h: h)
        case .calendar:    CalendarBody(instance: instance, w: w, h: h)
        case .countdown:   CountdownBody(instance: instance, w: w, h: h)
        case .weather:     WeatherBody(instance: instance, w: w, h: h)
        }
    }
}

private struct DateTimeBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let state = instance.payload.dateTimeState ?? DateTimeWidgetState()
        ZStack {
            WidgetClockStyle.gradient(state.backgroundHexes)
            TimelineView(.everyMinute) { context in
                ClockFace(state: state, date: context.date)
            }
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

private struct CalendarBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let state = instance.payload.dateTimeState ?? DateTimeWidgetState()
        ZStack {
            WidgetClockStyle.gradient(state.backgroundHexes)
            TimelineView(.everyMinute) { context in
                CalendarFace(state: state, date: context.date, wide: instance.family != .small)
            }
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

private struct CalendarFace: View {
    let state: DateTimeWidgetState
    let date: Date
    let wide: Bool

    var body: some View {
        let tint = Color(hex: state.tintHex) ?? .white
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height)
            HStack(alignment: .center, spacing: unit * 0.1) {
                if wide {
                    VStack(alignment: .leading, spacing: unit * 0.01) {
                        Text(WidgetClockStyle.weekday(date))
                            .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.13))
                            .minimumScaleFactor(0.5)
                        Text("\(Calendar.current.component(.day, from: date))")
                            .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.42))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                monthGrid(unit: unit, tint: tint)
            }
            .foregroundStyle(tint)
            .padding(unit * 0.1)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func monthGrid(unit: CGFloat, tint: Color) -> some View {
        let cal = Calendar.current
        let today = cal.component(.day, from: date)
        let cells = Self.cells(for: date, calendar: cal)
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        let symbols = Self.weekdaySymbols(calendar: cal)
        let cellFont = unit * (rows.count > 5 ? 0.068 : 0.075)
        return VStack(spacing: unit * 0.012) {
            Text(date.formatted(.dateTime.month(.wide)).uppercased())
                .font(.system(size: unit * 0.075, weight: .heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: cellFont, weight: .bold))
                        .opacity(0.6)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                        ZStack {
                            if day == today {
                                Circle().fill(tint)
                            }
                            if let day {
                                Text("\(day)")
                                    .font(.system(size: cellFont, weight: day == today ? .heavy : .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(day == today ? Self.contrast(for: state.tintHex) : tint)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: cellFont * 1.6)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private static func cells(for date: Date, calendar cal: Calendar) -> [Int?] {
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: date)),
              let range = cal.range(of: .day, in: .month, for: date) else { return [] }
        let leading = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        var cells: [Int?] = Array(repeating: nil, count: leading) + range.map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private static func weekdaySymbols(calendar cal: Calendar) -> [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let shift = (cal.firstWeekday - 1) % max(1, symbols.count)
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private static func contrast(for hex: String) -> Color {
        WidgetClockStyle.suggestedTint(for: [hex]) == "#111111" ? .black : .white
    }
}

private struct CountdownBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let state = instance.payload.dateTimeState ?? DateTimeWidgetState()
        ZStack {
            WidgetClockStyle.gradient(state.backgroundHexes)
            TimelineView(.everyMinute) { context in
                CountdownFace(state: state, now: context.date, wide: instance.family != .small)
            }
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

private struct CountdownFace: View {
    let state: DateTimeWidgetState
    let now: Date
    let wide: Bool

    var body: some View {
        let tint = Color(hex: state.tintHex) ?? .white
        let target = state.countdownTarget ?? now
        let title = state.countdownTitle.isEmpty ? String(localized: "Countdown") : state.countdownTitle
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height)
            VStack(alignment: .leading, spacing: unit * 0.02) {
                Text(title)
                    .font(.system(size: unit * 0.11, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                remaining(target: target, unit: unit)
                Text(target.formatted(date: wide ? .long : .abbreviated, time: .omitted))
                    .font(.system(size: unit * 0.085, weight: .semibold))
                    .opacity(0.75)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(tint)
            .padding(unit * 0.12)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
        }
    }

    @ViewBuilder
    private func remaining(target: Date, unit: CGFloat) -> some View {
        let seconds = target.timeIntervalSince(now)
        if seconds <= 0 {
            Text("Done")
                .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.3))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        } else if seconds < 86_400 {
            Text(Self.hoursMinutes(seconds))
                .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.3))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        } else {
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: target)).day ?? 0
            HStack(alignment: .firstTextBaseline, spacing: unit * 0.03) {
                Text("\(days)")
                    .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.4))
                    .monospacedDigit()
                Text(days == 1 ? String(localized: "day left") : String(localized: "days left"))
                    .font(.system(size: unit * 0.09, weight: .heavy))
                    .opacity(0.85)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.4)
        }
    }

    private static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropLeading
        return f.string(from: max(60, seconds)) ?? ""
    }
}

private struct WeatherBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let state = instance.payload.dateTimeState ?? DateTimeWidgetState()
        ZStack {
            WidgetClockStyle.gradient(state.backgroundHexes)
            WeatherFace(state: state, wide: instance.family != .small)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

private struct WeatherFace: View {
    let state: DateTimeWidgetState
    let wide: Bool
    private var weather: WidgetWeather { WidgetWeather.shared }

    var body: some View {
        let tint = Color(hex: state.tintHex) ?? .white
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height)
            content(unit: unit)
                .foregroundStyle(tint)
                .padding(unit * 0.12)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
        }
        .task(id: coordinateKey) { await refreshLoop() }
    }

    private var coordinateKey: String? {
        guard let lat = state.weatherLatitude, let lon = state.weatherLongitude else { return nil }
        return WidgetWeather.key(latitude: lat, longitude: lon)
    }

    private func refreshLoop() async {
        guard let lat = state.weatherLatitude, let lon = state.weatherLongitude else { return }
        while !Task.isCancelled {
            await weather.refreshIfNeeded(latitude: lat, longitude: lon)
            let failing = weather.isFailing(latitude: lat, longitude: lon)
            try? await Task.sleep(for: .seconds(failing ? 60 : 15 * 60))
        }
    }

    @ViewBuilder
    private func content(unit: CGFloat) -> some View {
        if let lat = state.weatherLatitude, let lon = state.weatherLongitude {
            let reading = weather.reading(latitude: lat, longitude: lon)
            let offline = weather.isFailing(latitude: lat, longitude: lon)
            if let reading {
                readingView(reading, offline: offline, unit: unit)
            } else if offline {
                placeholder(symbol: "wifi.slash", text: String(localized: "Weather unavailable offline"), unit: unit)
            } else {
                VStack(alignment: .leading, spacing: unit * 0.04) {
                    cityLabel(unit: unit)
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        } else {
            placeholder(symbol: "location.slash", text: String(localized: "Set a city in the widget editor"), unit: unit)
        }
    }

    private func cityLabel(unit: CGFloat) -> some View {
        Text(state.weatherCity.components(separatedBy: ",").first ?? state.weatherCity)
            .font(.system(size: unit * 0.1, weight: .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func readingView(_ reading: WidgetWeatherReading, offline: Bool, unit: CGFloat) -> some View {
        let symbol = WidgetWeather.symbol(code: reading.code, isDay: reading.isDay)
        let range = [reading.high.map { String(localized: "H \(WidgetWeather.temperature($0))") },
                     reading.low.map { String(localized: "L \(WidgetWeather.temperature($0))") }]
            .compactMap { $0 }.joined(separator: "  ")
        return VStack(alignment: .leading, spacing: unit * 0.02) {
            HStack(spacing: unit * 0.04) {
                cityLabel(unit: unit)
                if offline {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: unit * 0.07, weight: .bold))
                        .opacity(0.7)
                }
                Spacer(minLength: 0)
                if wide {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: unit * 0.3))
                }
            }
            Spacer(minLength: 0)
            Text(WidgetWeather.temperature(reading.temperature))
                .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.34))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: unit * 0.04) {
                if !wide {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: unit * 0.1))
                }
                Text(WidgetWeather.label(code: reading.code))
                    .font(.system(size: unit * 0.085, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if !range.isEmpty {
                Text(range)
                    .font(.system(size: unit * 0.075, weight: .semibold))
                    .opacity(0.75)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private func placeholder(symbol: String, text: String, unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.05) {
            if !state.weatherCity.isEmpty { cityLabel(unit: unit) }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: unit * 0.18, weight: .semibold))
            Text(text)
                .font(.system(size: unit * 0.085, weight: .semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

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

private struct FocalFillImage: View {
    let image: NSImage
    var fill: Bool = true
    var offset: CGPoint = .zero
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        if fill {
            let imgSize = image.size
            let zoom = max(w / max(imgSize.width, 1), h / max(imgSize.height, 1)) * 1.12
            let sw = imgSize.width * zoom
            let sh = imgSize.height * zoom
            let maxX = max(0, (sw - w) / 2)
            let maxY = max(0, (sh - h) / 2)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: sw, height: sh)
                .offset(x: offset.x * maxX, y: offset.y * maxY)
                .frame(width: w, height: h)
                .clipped()
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: w, height: h)
        }
    }
}

private struct PhotoBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    @State private var images: [NSImage] = []
    @State private var index = 0

    var body: some View {
        let state = photoState
        ZStack {
            Color.black.opacity(0.25)
            if images.isEmpty {
                placeholder
            } else {
                let safe = min(index, images.count - 1)
                FocalFillImage(image: images[safe], fill: state.fill,
                               offset: CGPoint(x: state.offsetX, y: state.offsetY), w: w, h: h)
                    .id(safe)
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: h)
        .task(id: imagesKey) { loadImages() }
        .task(id: images.count) { await runSlideshow() }
    }

    private var photoState: PhotoWidgetState {
        if case .photo(let s) = instance.payload { return s }
        return PhotoWidgetState()
    }

    private var imagesKey: String {
        instance.id.uuidString + "|" + photoState.relativePaths.joined(separator: ",")
    }

    @MainActor
    private func loadImages() {
        images = photoState.relativePaths.prefix(8).compactMap {
            WidgetRenderAssets.userImage($0, in: instance.id, maxPixelSize: 900)
        }
        index = 0
    }

    private func runSlideshow() async {
        guard images.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, images.count > 1 else { continue }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % images.count }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: min(w, h) * 0.22))
            Text("Add photo").font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

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

private struct VideoBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let state = videoState
        let url = state.relativePath.isEmpty ? nil
            : WidgetStore.shared.assetURL(for: state.relativePath, in: instance.id)
        ZStack {
            Color.black
            if let url {
                WidgetVideoPlayerView(url: url, fill: state.fill)
                    .scaleEffect(state.fill ? 1.18 : 1)
                    .offset(x: state.offsetX * w * 0.12, y: state.offsetY * h * 0.12)
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video").font(.system(size: min(w, h) * 0.22))
                    Text("Add video").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: w, height: h)
        .clipped()
    }

    private var videoState: VideoWidgetState {
        if case .video(let s) = instance.payload { return s }
        return VideoWidgetState()
    }
}

private struct WidgetVideoPlayerView: NSViewRepresentable {
    let url: URL
    var fill: Bool = true

    func makeNSView(context: Context) -> LoopingVideoView { LoopingVideoView() }
    func updateNSView(_ view: LoopingVideoView, context: Context) { view.configure(url: url, fill: fill) }
    static func dismantleNSView(_ view: LoopingVideoView, coordinator: ()) { view.stop() }
}

final class LoopingVideoView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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

    func configure(url: URL, fill: Bool) {
        playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        guard url != currentURL else { return }
        currentURL = url
        stop()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        playerLayer.player = queue
        queue.play()
        player = queue
    }

    func stop() {
        player?.pause()
        looper = nil
        playerLayer.player = nil
        player = nil
    }
}

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
            if let bg = WidgetRenderAssets.themeImage(slug: slug, name: "frame4") {
                ImageLayer(image: bg).frame(width: w, height: h).clipped()
            } else {
                Color(red: 0.18, green: 0.18, blue: 0.18)
            }
            ImageLayer(image: photo).frame(width: w, height: h).clipped()
                .scaleEffect(isClosed ? closedScale : 1.0)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h)
                .offset(x: isClosed ? 0 : -w)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame2"))
                .frame(width: w, height: h)
                .offset(x: isClosed ? 0 : w)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame5"))
                .frame(width: w, height: h).clipped()
                .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

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
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h, alignment: .top)
                .offset(y: isClosed ? 0 : -slide)
                .animation(.easeOut(duration: 0.55), value: isClosed)
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame2"))
                .frame(width: w, height: h, alignment: .bottom)
                .offset(y: isClosed ? 0 : slide)
                .animation(.easeOut(duration: 0.55), value: isClosed)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

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
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h).clipped()
                .offset(y: isClosed ? 0 : -h)
                .animation(.easeOut(duration: 0.55), value: isClosed)
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

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
            if let bg = WidgetRenderAssets.themeImage(slug: slug, name: "frame3") {
                ImageLayer(image: bg).frame(width: w, height: h).clipped()
            } else {
                Color(red: 0.30, green: 0.55, blue: 0.85)
            }
            ImageLayer(image: photo).frame(width: w, height: h).clipped()
                .offset(y: isHidden ? hiddenY : visibleY)
                .animation(.easeOut(duration: 0.55), value: isHidden)
            ImageLayer(image: WidgetRenderAssets.themeImage(slug: slug, name: "frame1"))
                .frame(width: w, height: h).clipped()
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

private struct DIYAnimatedBody: View {
    let instance: WidgetInstance
    let isAnimating: Bool
    let w: CGFloat
    let h: CGFloat

    @State private var frameIndex = 0
    @State private var frames: [NSImage] = []
    @State private var cover: NSImage?

    var body: some View {
        ZStack {
            Color.white
            content
        }
        .frame(width: w, height: h)
        .task(id: frameKey) { loadAssets() }
        .task(id: isAnimating) {
            guard isAnimating else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 12)
                guard !Task.isCancelled, !frames.isEmpty else { continue }
                frameIndex = (frameIndex + 1) % frames.count
            }
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

private struct PolaroidBody: View {
    let instance: WidgetInstance
    let step: Int
    let w: CGFloat
    let h: CGFloat

    @State private var images: [NSImage] = []

    private struct Slot { var offset: CGSize; var rotation: Double; var scale: CGFloat; var opacity: Double; var z: Double }

    var body: some View {
        let count = images.count
        ZStack {
            background(polaroidState.background)
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
        .task(id: imagesKey) { loadImages() }
        .animation(.smooth(duration: 0.55), value: step)
    }

    private var imagesKey: String {
        instance.id.uuidString + "|" + polaroidState.relativePaths.joined(separator: ",")
    }

    @MainActor
    private func loadImages() {
        images = polaroidState.relativePaths.compactMap {
            WidgetRenderAssets.userImage($0, in: instance.id, maxPixelSize: 600)
        }
    }

    private func slot(distance: Int, count: Int) -> Slot {
        if count >= 3 && distance == count - 1 {
            return Slot(offset: CGSize(width: -w * 0.85, height: -6), rotation: -16, scale: 0.9, opacity: 0, z: 120)
        }
        switch distance {
        case 0:  return Slot(offset: .zero, rotation: -4, scale: 1.0, opacity: 1, z: 100)
        case 1:  return Slot(offset: CGSize(width: w * 0.07, height: -h * 0.05), rotation: 6, scale: 0.93, opacity: 1, z: 90)
        case 2:  return Slot(offset: CGSize(width: -w * 0.06, height: h * 0.04), rotation: -8, scale: 0.88, opacity: 0.95, z: 80)
        default: return Slot(offset: .zero, rotation: 0, scale: 0.85, opacity: 0, z: 10)
        }
    }

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

private struct TemplateBody: View {
    let instance: WidgetInstance
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            if let slug = instance.payload.templateSlug, MatchesLiveView.handles(slug: slug) {
                // The World Cup widget is data-driven — render the live scoreboard, not a static image.
                MatchesLiveView(width: w, height: h)
                    .frame(width: w, height: h)
            } else if let slug = instance.payload.templateSlug {
                WidgetTemplateView(slug: slug,
                                   family: instance.family,
                                   userPhotoURL: photoURL,
                                   fallbackThumbnailURL: instance.payload.templateThumbnailURL)
                    .frame(width: w, height: h)
            } else if let localImage = WidgetRenderAssets.userImage(instance.payload.templatePreviewPath, in: instance.id, maxPixelSize: 900) {
                Image(nsImage: localImage).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fill).frame(width: w, height: h).clipped()
            } else if let thumb = instance.payload.templateThumbnailURL {
                ThumbnailView(url: thumb, placeholderTint: .black.opacity(0.15))
                    .frame(width: w, height: h).clipped()
            } else {
                VStack(spacing: min(w, h) * 0.05) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.system(size: min(w, h) * 0.18, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(instance.name)
                        .font(.system(size: max(9, min(w, h) * 0.085), weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(min(w, h) * 0.08)
                .frame(width: w, height: h)
                .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: w, height: h)
    }

    private var photoURL: URL? {
        guard let rel = instance.payload.templatePhotoPath, !rel.isEmpty else { return nil }
        return WidgetStore.shared.assetURL(for: rel, in: instance.id)
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

// MARK: - Live World Cup widget (data-driven "template")

struct WCMatch: Decodable, Identifiable, Sendable {
    let id: String
    let home: String
    let away: String
    let homeScore: String
    let awayScore: String
    let dateString: String
    let finished: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case home = "home_team_name_en"
        case away = "away_team_name_en"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case dateString = "local_date"
        case finished
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        home = (try? c.decode(String.self, forKey: .home)) ?? "—"
        away = (try? c.decode(String.self, forKey: .away)) ?? "—"
        homeScore = (try? c.decode(String.self, forKey: .homeScore)) ?? ""
        awayScore = (try? c.decode(String.self, forKey: .awayScore)) ?? ""
        dateString = (try? c.decode(String.self, forKey: .dateString)) ?? ""
        finished = ((try? c.decode(String.self, forKey: .finished)) ?? "FALSE").uppercased() == "TRUE"
    }

    init(id: String, home: String, away: String, homeScore: String, awayScore: String, dateString: String, finished: Bool) {
        self.id = id; self.home = home; self.away = away
        self.homeScore = homeScore; self.awayScore = awayScore
        self.dateString = dateString; self.finished = finished
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd/yyyy HH:mm"; return f
    }()
    var kickoff: Date? { Self.parser.date(from: dateString) }
}

private struct WCMatchesResponse: Decodable { let games: [WCMatch] }

enum MatchesLiveData {
    private static let base = "https://backend.wallpics.app"
    private static let salt = "wall"

    static func fetch() async -> [WCMatch] {
        guard let url = URL(string: "\(base)/api/world-cup/games") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 12)
        let ts = String(Int(Date().timeIntervalSince1970))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("MacOS", forHTTPHeaderField: "X-App-Platform")
        req.setValue(ts, forHTTPHeaderField: "x-auth")
        req.setValue(md5(ts + salt), forHTTPHeaderField: "x-token")
        req.setValue("1", forHTTPHeaderField: "x-get-guest-id")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let decoded = try? JSONDecoder().decode(WCMatchesResponse.self, from: data) else { return [] }
        return decoded.games
    }

    static func relevant(_ games: [WCMatch], limit: Int, now: Date = Date()) -> [WCMatch] {
        let named = games.filter { $0.home != "—" && $0.away != "—" && !$0.home.isEmpty && !$0.away.isEmpty }
        func started(_ g: WCMatch) -> Bool { g.kickoff.map { $0 <= now } ?? false }
        let live = named.filter { !$0.finished && started($0) }
        let rest = named.filter { $0.finished || !started($0) }
            .sorted { abs(($0.kickoff ?? .distantPast).timeIntervalSince(now)) < abs(($1.kickoff ?? .distantPast).timeIntervalSince(now)) }
        return Array((live + rest).prefix(limit))
    }

    static let sample: [WCMatch] = [
        WCMatch(id: "s1", home: "Brazil", away: "Norway", homeScore: "2", awayScore: "1", dateString: "", finished: true),
        WCMatch(id: "s2", home: "France", away: "Japan", homeScore: "3", awayScore: "0", dateString: "", finished: true),
        WCMatch(id: "s3", home: "Spain", away: "Morocco", homeScore: "1", awayScore: "1", dateString: "", finished: true),
        WCMatch(id: "s4", home: "Argentina", away: "Mexico", homeScore: "2", awayScore: "0", dateString: "", finished: true),
        WCMatch(id: "s5", home: "Germany", away: "Portugal", homeScore: "0", awayScore: "2", dateString: "", finished: true),
        WCMatch(id: "s6", home: "England", away: "Croatia", homeScore: "1", awayScore: "0", dateString: "", finished: true)
    ]

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum WCFlags {
    private static let map: [String: String] = [
        "algeria": "🇩🇿", "argentina": "🇦🇷", "australia": "🇦🇺", "austria": "🇦🇹", "belgium": "🇧🇪",
        "bosnia and herzegovina": "🇧🇦", "brazil": "🇧🇷", "canada": "🇨🇦", "cape verde": "🇨🇻", "colombia": "🇨🇴",
        "croatia": "🇭🇷", "curaçao": "🇨🇼", "curacao": "🇨🇼", "czech republic": "🇨🇿",
        "democratic republic of the congo": "🇨🇩", "ecuador": "🇪🇨", "egypt": "🇪🇬", "england": "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
        "france": "🇫🇷", "germany": "🇩🇪", "ghana": "🇬🇭", "haiti": "🇭🇹", "iran": "🇮🇷", "iraq": "🇮🇶",
        "ivory coast": "🇨🇮", "japan": "🇯🇵", "jordan": "🇯🇴", "mexico": "🇲🇽", "morocco": "🇲🇦",
        "netherlands": "🇳🇱", "new zealand": "🇳🇿", "norway": "🇳🇴", "panama": "🇵🇦", "paraguay": "🇵🇾",
        "portugal": "🇵🇹", "qatar": "🇶🇦", "saudi arabia": "🇸🇦", "scotland": "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "senegal": "🇸🇳",
        "south africa": "🇿🇦", "south korea": "🇰🇷", "spain": "🇪🇸", "sweden": "🇸🇪", "switzerland": "🇨🇭",
        "tunisia": "🇹🇳", "turkey": "🇹🇷", "united states": "🇺🇸", "usa": "🇺🇸", "uruguay": "🇺🇾", "uzbekistan": "🇺🇿"
    ]
    static func emoji(_ team: String) -> String {
        map[team.lowercased().trimmingCharacters(in: .whitespaces)] ?? "⚽️"
    }
}

/// Live World Cup scoreboard rendered inside the desktop overlay — pulls api/world-cup/games and
/// refreshes on its own. Scales across the small/medium/large desktop widget sizes.
struct MatchesLiveView: View {
    let width: CGFloat
    let height: CGFloat
    @State private var games: [WCMatch] = MatchesLiveData.sample
    @State private var loaded = false

    static func handles(slug: String) -> Bool {
        let s = slug.lowercased()
        return s.contains("world_cup") || s.contains("world-cup") || s.contains("worldcup") || s.contains("matches")
    }

    private var scale: CGFloat { max(0.72, min(width / 360, 1.25)) }
    private var rowCount: Int { height > 340 ? 6 : (height > 210 ? 4 : 3) }

    var body: some View {
        let shown = MatchesLiveData.relevant(games, limit: rowCount)
        VStack(alignment: .leading, spacing: 7 * scale) {
            HStack(spacing: 6 * scale) {
                Image(systemName: "soccerball").font(.system(size: 13 * scale, weight: .bold))
                Text("TODAY'S MATCHES").font(.system(size: 12 * scale, weight: .heavy)).tracking(0.4).lineLimit(1)
                Spacer(minLength: 4)
                Text(headerDate).font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
            if shown.isEmpty {
                Spacer()
                Text("No matches available").font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(shown) { g in
                    row(g)
                    if g.id != shown.last?.id { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 12 * scale)
        .frame(width: width, height: height)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.20, blue: 0.11), Color(red: 0.03, green: 0.09, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
        )
        .task {
            guard !loaded else { return }
            let g = await MatchesLiveData.fetch()
            if !g.isEmpty { games = g }
            loaded = true
        }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            Task { let g = await MatchesLiveData.fetch(); if !g.isEmpty { games = g } }
        }
    }

    private func row(_ g: WCMatch) -> some View {
        HStack(spacing: 6 * scale) {
            HStack(spacing: 5 * scale) {
                Spacer(minLength: 0)
                Text(g.home).lineLimit(1).minimumScaleFactor(0.65)
                Text(WCFlags.emoji(g.home)).font(.system(size: 13 * scale))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Text(score(g)).font(.system(size: 14 * scale, weight: .heavy, design: .rounded)).monospacedDigit().frame(width: 56 * scale)
            HStack(spacing: 5 * scale) {
                Text(WCFlags.emoji(g.away)).font(.system(size: 13 * scale))
                Text(g.away).lineLimit(1).minimumScaleFactor(0.65)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12 * scale, weight: .semibold))
        .foregroundStyle(.white)
    }

    private func score(_ g: WCMatch) -> String {
        let started = g.kickoff.map { $0 <= Date() } ?? false
        if (g.finished || started), !g.homeScore.isEmpty, !g.awayScore.isEmpty {
            return "\(g.homeScore) - \(g.awayScore)"
        }
        if let k = g.kickoff { return Self.timeFmt.string(from: k) }
        return "vs"
    }

    private var headerDate: String {
        let shown = MatchesLiveData.relevant(games, limit: rowCount)
        if let k = shown.compactMap(\.kickoff).min() { return Self.dayFmt.string(from: k) }
        return Self.dayFmt.string(from: Date())
    }

    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM"; return f }()
}

