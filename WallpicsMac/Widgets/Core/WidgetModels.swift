import Foundation
import CoreGraphics
import SwiftUI

enum WidgetFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .small:  return 1
        case .medium: return 384.0 / 180.0
        case .large:  return 384.0 / 402.0
        }
    }

    var desktopSize: CGSize {
        switch self {
        case .small:  return CGSize(width: 180, height: 180)
        case .medium: return CGSize(width: 384, height: 180)
        case .large:  return CGSize(width: 384, height: 402)
        }
    }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo
    case video
    case staticImage
    case polaroid
    case elevator
    case openedEyes
    case garageDoor
    case windowsXP
    case diyAnimated
    case template
    case dateTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photo:       return String(localized: "Photo")
        case .video:       return String(localized: "Video")
        case .staticImage: return String(localized: "Image")
        case .polaroid:    return String(localized: "Polaroid")
        case .elevator:    return String(localized: "Elevator")
        case .openedEyes:  return String(localized: "Opened Eyes")
        case .garageDoor:  return String(localized: "Garage Door")
        case .windowsXP:   return String(localized: "Windows XP")
        case .diyAnimated: return String(localized: "DIY Animated")
        case .template:    return String(localized: "Template")
        case .dateTime:    return String(localized: "Clock")
        }
    }

    var symbol: String {
        switch self {
        case .photo:       return "photo"
        case .video:       return "video"
        case .staticImage: return "photo.artframe"
        case .polaroid:    return "photo.stack"
        case .elevator:    return "rectangle.split.2x1"
        case .openedEyes:  return "eye"
        case .garageDoor:  return "door.garage.closed"
        case .windowsXP:   return "mountain.2"
        case .diyAnimated: return "wand.and.stars"
        case .template:    return "square.grid.2x2"
        case .dateTime:    return "clock"
        }
    }

    var isInteractive: Bool {
        switch self {
        case .elevator, .openedEyes, .garageDoor, .windowsXP, .diyAnimated, .polaroid: return true
        default: return false
        }
    }

    var themeSlug: String? {
        switch self {
        case .elevator:   return "elevator"
        case .openedEyes: return "opened_eyes"
        case .garageDoor: return "garage_door"
        case .windowsXP:  return "windows_xp"
        default:          return nil
        }
    }

    var supportedFamilies: [WidgetFamily] {
        switch self {
        case .photo, .video, .staticImage, .template: return [.small, .medium, .large]
        case .polaroid, .dateTime:                    return [.small, .medium]
        default:                                      return [.small]
        }
    }
}

struct PhotoWidgetState: Codable, Equatable, Sendable {
    var relativePaths: [String] = []
    var fill: Bool = true
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
}

struct VideoWidgetState: Codable, Equatable, Sendable {
    var relativePath: String = ""
    var fill: Bool = true
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
}

struct StaticImageState: Codable, Equatable, Sendable {
    var relativePath: String = ""
    var sourceSlug: String? = nil
}

struct PolaroidWidgetState: Codable, Equatable, Sendable {
    enum Background: Codable, Equatable, Sendable {
        case transparent
        case album(relativePath: String)
        case color(hexes: [String])
    }
    var frameVariantID: String = "frame1"
    var relativePaths: [String] = []
    var background: Background = .transparent
}

struct ThemedToggleState: Codable, Equatable, Sendable {
    var photoRelativePath: String? = nil
    var isClosed: Bool = false
}

struct DIYAnimatedWidgetState: Codable, Equatable, Sendable {
    var templateSlug: String = ""
    var photoRelativePath: String? = nil
    var bakedFrameRelativePaths: [String] = []
    var coverRelativePath: String? = nil
    var isOpen: Bool = false
}

struct TemplateWidgetState: Codable, Equatable, Sendable {
    var templateSlug: String = ""
    var sizeFolder: String = "small"
    var photoRelativePath: String? = nil
    var replacements: [String: String] = [:]
    var previewRelativePath: String? = nil
    var thumbnailURLString: String? = nil
}

struct DateTimeWidgetState: Codable, Equatable, Hashable, Sendable {
    enum Style: String, Codable, Equatable, Hashable, Sendable {
        case time, date, timeAndDate
    }
    var style: Style = .timeAndDate
    var backgroundHexes: [String] = ["#FF7A1A", "#F5520B"]
    var tintHex: String = "#FFFFFF"
    var fontKey: String = "rounded"
    var use24Hour: Bool = false
}

enum WidgetPayload: Codable, Equatable, Sendable {
    case photo(PhotoWidgetState)
    case video(VideoWidgetState)
    case staticImage(StaticImageState)
    case polaroid(PolaroidWidgetState)
    case themed(ThemedToggleState)
    case diyAnimated(DIYAnimatedWidgetState)
    case template(TemplateWidgetState)
    case dateTime(DateTimeWidgetState)
}

extension WidgetPayload {
    var relativePaths: [String]? {
        switch self {
        case .photo(let s): return s.relativePaths
        case .polaroid(let s): return s.relativePaths
        default: return nil
        }
    }

    var themedPhotoPath: String? {
        if case .themed(let s) = self { return s.photoRelativePath }
        return nil
    }

    var staticImagePath: String? {
        if case .staticImage(let s) = self { return s.relativePath.isEmpty ? nil : s.relativePath }
        return nil
    }

    var templatePreviewPath: String? {
        if case .template(let s) = self { return s.previewRelativePath }
        return nil
    }

    var templateThumbnailURL: URL? {
        if case .template(let s) = self { return s.thumbnailURLString.flatMap(URL.init(string:)) }
        return nil
    }

    var templateSlug: String? {
        if case .template(let s) = self { return s.templateSlug.isEmpty ? nil : s.templateSlug }
        return nil
    }

    var templatePhotoPath: String? {
        if case .template(let s) = self { return s.photoRelativePath }
        return nil
    }

    var photoFill: Bool {
        if case .photo(let s) = self { return s.fill }
        return true
    }

    var videoPath: String? {
        if case .video(let s) = self { return s.relativePath.isEmpty ? nil : s.relativePath }
        return nil
    }

    var videoFill: Bool {
        if case .video(let s) = self { return s.fill }
        return true
    }

    var focalOffset: CGPoint {
        switch self {
        case .photo(let s): return CGPoint(x: s.offsetX, y: s.offsetY)
        case .video(let s): return CGPoint(x: s.offsetX, y: s.offsetY)
        default: return .zero
        }
    }

    func sharedImageRelativePath() -> String? {
        switch self {
        case .photo(let s):       return s.relativePaths.first
        case .video:              return nil
        case .staticImage(let s): return s.relativePath.isEmpty ? nil : s.relativePath
        case .polaroid(let s):    return s.relativePaths.first
        case .themed(let s):      return s.photoRelativePath
        case .diyAnimated(let s): return s.coverRelativePath ?? s.bakedFrameRelativePaths.first ?? s.photoRelativePath
        case .template(let s):    return s.previewRelativePath ?? s.photoRelativePath
        case .dateTime:           return nil
        }
    }

    var dateTimeState: DateTimeWidgetState? {
        if case .dateTime(let s) = self { return s }
        return nil
    }
}

enum WidgetSharedConfig {
    static let appGroupID = "group.com.kyragames.AestheticSadWallpapers"
    static let renderFileName = "render.png"
}

struct WidgetInstance: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: WidgetKind
    var family: WidgetFamily
    var name: String
    var payload: WidgetPayload
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         kind: WidgetKind,
         family: WidgetFamily,
         name: String,
         payload: WidgetPayload,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.family = family
        self.name = name
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Color {
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

enum WidgetClockStyle {
    static let fontKeys = ["rounded", "default", "serif", "mono"]
    static let backgroundChoices: [[String]] = [
        ["#FF7A1A", "#F5520B"], ["#111111", "#222222"], ["#FFFFFF", "#EDEDED"],
        ["#FF5E7E", "#FF3D6E"], ["#6C5CE7", "#4B3FD1"], ["#1FB6A6", "#0E8A7D"],
        ["#2D9CFF", "#1466C7"], ["#FFB300", "#FF8A00"]
    ]
    static let tintChoices = ["#FFFFFF", "#111111", "#FFF3D6", "#0E1430"]

    static func suggestedTint(for hexes: [String]) -> String {
        guard var s = hexes.first else { return "#FFFFFF" }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt64(s.prefix(6), radix: 16) else { return "#FFFFFF" }
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        return luminance > 0.6 ? "#111111" : "#FFFFFF"
    }

    static func font(for key: String, size: CGFloat) -> Font {
        switch key {
        case "serif":   return .system(size: size, weight: .heavy, design: .serif)
        case "mono":    return .system(size: size, weight: .bold, design: .monospaced)
        case "default": return .system(size: size, weight: .bold)
        default:        return .system(size: size, weight: .bold, design: .rounded)
        }
    }

    static func gradient(_ hexes: [String]) -> LinearGradient {
        let colors = hexes.compactMap(Color.init(hex:))
        let safe = colors.isEmpty ? [Color(white: 0.12), Color(white: 0.04)] : colors
        return LinearGradient(colors: safe.count == 1 ? [safe[0], safe[0]] : safe,
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func timeString(_ date: Date, use24Hour: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = use24Hour ? "HH:mm" : "h:mm"
        return f.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f.string(from: date).uppercased()
    }
}

struct ClockFace: View {
    let state: DateTimeWidgetState
    let date: Date

    var body: some View {
        let tint = Color(hex: state.tintHex) ?? .white
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height)
            content(unit: unit, tint: tint)
                .padding(unit * 0.13)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: state.style == .time ? .center : .leading)
                .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
        }
    }

    @ViewBuilder
    private func content(unit: CGFloat, tint: Color) -> some View {
        switch state.style {
        case .time:
            Text(WidgetClockStyle.timeString(date, use24Hour: state.use24Hour))
                .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.44))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .date:
            VStack(alignment: .leading, spacing: unit * 0.01) {
                Spacer(minLength: 0)
                Text(WidgetClockStyle.weekday(date))
                    .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.28))
                    .minimumScaleFactor(0.4)
                Text(WidgetClockStyle.monthDay(date))
                    .font(.system(size: unit * 0.12, weight: .heavy))
                    .opacity(0.9)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .timeAndDate:
            VStack(alignment: .leading, spacing: unit * 0.015) {
                Spacer(minLength: 0)
                Text(WidgetClockStyle.weekday(date))
                    .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.20))
                    .minimumScaleFactor(0.5)
                Text(WidgetClockStyle.monthDay(date))
                    .font(.system(size: unit * 0.10, weight: .heavy)).opacity(0.85)
                Text(WidgetClockStyle.timeString(date, use24Hour: state.use24Hour))
                    .font(WidgetClockStyle.font(for: state.fontKey, size: unit * 0.30))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .padding(.top, unit * 0.03)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
