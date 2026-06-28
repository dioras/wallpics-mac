import Foundation
import CoreGraphics

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
        case .small: return 1
        case .medium: return 2
        case .large: return 1
        }
    }

    var desktopSize: CGSize {
        switch self {
        case .small:  return CGSize(width: 200, height: 200)
        case .medium: return CGSize(width: 416, height: 200)
        case .large:  return CGSize(width: 416, height: 416)
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
        case .polaroid:                               return [.small, .medium]
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

enum WidgetPayload: Codable, Equatable, Sendable {
    case photo(PhotoWidgetState)
    case video(VideoWidgetState)
    case staticImage(StaticImageState)
    case polaroid(PolaroidWidgetState)
    case themed(ThemedToggleState)
    case diyAnimated(DIYAnimatedWidgetState)
    case template(TemplateWidgetState)
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
