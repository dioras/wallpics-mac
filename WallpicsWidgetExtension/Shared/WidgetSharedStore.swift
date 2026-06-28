import Foundation
import ImageIO
import CoreGraphics
import SwiftUI

struct SharedWidget: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kindRawValue: String
    let familyRawValue: String
    let primaryImageRelativePath: String?

    var displayName: String {
        name.isEmpty ? displayKind : name
    }

    var displayKind: String {
        switch kindRawValue {
        case "photo":       return "Photo"
        case "video":       return "Video"
        case "staticImage": return "Image"
        case "polaroid":    return "Polaroid"
        case "elevator":    return "Elevator"
        case "openedEyes":  return "Opened Eyes"
        case "garageDoor":  return "Garage Door"
        case "windowsXP":   return "Windows XP"
        case "diyAnimated": return "DIY Animated"
        case "template":    return "Template"
        default:            return "Widget"
        }
    }
}

struct WidgetSharedStore: Sendable {
    static let appGroupID = "group.com.kyragames.AestheticSadWallpapers"
    static let shared = WidgetSharedStore()

    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    var widgetsRoot: URL? {
        containerURL?.appendingPathComponent("Widgets", isDirectory: true)
    }

    var instancesFile: URL? {
        widgetsRoot?.appendingPathComponent("instances.json")
    }

    var instancesRoot: URL? {
        widgetsRoot?.appendingPathComponent("Instances", isDirectory: true)
    }

    func allWidgets() -> [SharedWidget] {
        guard let url = instancesFile,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let instances = try? decoder.decode([StoredWidgetInstance].self, from: data) else {
            return []
        }
        return instances
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { instance in
                SharedWidget(
                    id: instance.id.uuidString,
                    name: instance.name,
                    kindRawValue: instance.kind.rawValue,
                    familyRawValue: instance.family.rawValue,
                    primaryImageRelativePath: instance.payload.primaryRelativePath
                )
            }
    }

    func widget(id: String) -> SharedWidget? {
        allWidgets().first { $0.id == id }
    }

    func imageURL(for widget: SharedWidget) -> URL? {
        guard let relativePath = widget.primaryImageRelativePath,
              !relativePath.isEmpty,
              let root = instancesRoot else {
            return nil
        }
        let url = root
            .appendingPathComponent(widget.id, isDirectory: true)
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func cgImage(for widget: SharedWidget, maxPixelSize: Int = 1200) -> CGImage? {
        guard let url = imageURL(for: widget) else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    func image(for widget: SharedWidget, maxPixelSize: Int = 1200) -> Image? {
        guard let cg = cgImage(for: widget, maxPixelSize: maxPixelSize) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}

private enum StoredWidgetFamily: String, Codable, Sendable {
    case small, medium, large
}

private enum StoredWidgetKind: String, Codable, Sendable {
    case photo, video, staticImage, polaroid, elevator, openedEyes, garageDoor, windowsXP, diyAnimated, template
}

private struct StoredPhotoState: Codable, Sendable {
    var relativePaths: [String] = []
    var fill: Bool = true
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
}

private struct StoredVideoState: Codable, Sendable {
    var relativePath: String = ""
    var fill: Bool = true
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
}

private struct StoredStaticImageState: Codable, Sendable {
    var relativePath: String = ""
    var sourceSlug: String? = nil
}

private struct StoredPolaroidState: Codable, Sendable {
    enum Background: Codable, Sendable {
        case transparent
        case album(relativePath: String)
        case color(hexes: [String])
    }
    var frameVariantID: String = "frame1"
    var relativePaths: [String] = []
    var background: Background = .transparent
}

private struct StoredThemedState: Codable, Sendable {
    var photoRelativePath: String? = nil
    var isClosed: Bool = false
}

private struct StoredDIYAnimatedState: Codable, Sendable {
    var templateSlug: String = ""
    var photoRelativePath: String? = nil
    var bakedFrameRelativePaths: [String] = []
    var coverRelativePath: String? = nil
    var isOpen: Bool = false
}

private struct StoredTemplateState: Codable, Sendable {
    var templateSlug: String = ""
    var sizeFolder: String = "small"
    var photoRelativePath: String? = nil
    var replacements: [String: String] = [:]
    var previewRelativePath: String? = nil
    var thumbnailURLString: String? = nil
}

private enum StoredWidgetPayload: Codable, Sendable {
    case photo(StoredPhotoState)
    case video(StoredVideoState)
    case staticImage(StoredStaticImageState)
    case polaroid(StoredPolaroidState)
    case themed(StoredThemedState)
    case diyAnimated(StoredDIYAnimatedState)
    case template(StoredTemplateState)

    var primaryRelativePath: String? {
        switch self {
        case .photo(let s):
            return s.relativePaths.first
        case .video:
            return nil
        case .staticImage(let s):
            return s.relativePath.isEmpty ? nil : s.relativePath
        case .template(let s):
            return s.previewRelativePath
        case .polaroid(let s):
            return s.relativePaths.first
        case .themed(let s):
            return s.photoRelativePath
        case .diyAnimated(let s):
            return s.coverRelativePath ?? s.bakedFrameRelativePaths.first ?? s.photoRelativePath
        }
    }
}

private struct StoredWidgetInstance: Codable, Sendable {
    let id: UUID
    var kind: StoredWidgetKind
    var family: StoredWidgetFamily
    var name: String
    var payload: StoredWidgetPayload
    var createdAt: Date
    var updatedAt: Date
}
