import Foundation
import CoreGraphics

// Cross-platform widget model for the macOS port of the iOS Wallpics widget system.
//
// On iOS the widgets live in a WidgetKit extension and persist their state to an App Group
// that the extension reads back. macOS has no equivalent in-app home screen, so here we own
// the whole pipeline: the app renders each widget itself (see `WidgetRenderView`) and can
// place it as a live desktop overlay (see `DesktopWidgetManager`). That means we don't need
// an App Group / provisioning — instances persist to Application Support like the rest of the
// Mac app's data (`CacheManager`).
//
// The state structs below mirror the iOS `*WidgetState` shapes (photo file + a toggle flag,
// polaroid frame variant + photos, etc.) so the rendering stays faithful.

/// The widget canvas families ported from iOS. macOS desktop overlays render these at a
/// larger physical size than an iPhone home screen, but the aspect ratios are preserved.
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

    /// Canonical render aspect, matching iOS home-screen widget proportions
    /// (small/large are square, medium is 2:1).
    var aspectRatio: CGFloat {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .large: return 1
        }
    }

    /// Base point size used for in-app previews and the default desktop overlay size.
    /// Scaled up from the iPhone home-screen footprint so widgets read well on a Mac desktop.
    var desktopSize: CGSize {
        switch self {
        case .small:  return CGSize(width: 200, height: 200)
        case .medium: return CGSize(width: 416, height: 200)
        case .large:  return CGSize(width: 416, height: 416)
        }
    }
}

/// Every widget type ported from the iOS app. Lock-screen-only families (accessory circular /
/// rectangular / inline) and the iOS 26 control widget are intentionally excluded — they have no
/// macOS analog. Everything that renders on a home-screen surface is here.
enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo          // user photo(s), optionally rotating
    case staticImage    // backend-provided still image (NEW in the latest iOS build)
    case polaroid       // stacked / fanned polaroid carousel
    case elevator       // themed: doors slide open to reveal the photo (interactive)
    case openedEyes     // themed: torn-paper eyelids slide open (interactive)
    case garageDoor     // themed: door slides up to reveal the photo (interactive)
    case windowsXP      // themed: photo slides behind the Bliss hill (interactive)
    case diyAnimated    // template-driven baked-frame animation
    case template       // backend Widgify template (config.json + assets)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photo:       return String(localized: "Photo")
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

    /// Widgets that respond to a click on the desktop overlay — the themed reveal widgets toggle
    /// open/closed, DIY plays its animation, and the polaroid advances its carousel. (This
    /// interactivity is the one thing a real macOS WidgetKit extension couldn't reproduce.)
    var isInteractive: Bool {
        switch self {
        case .elevator, .openedEyes, .garageDoor, .windowsXP, .diyAnimated, .polaroid: return true
        default: return false
        }
    }

    /// Asset-bundle slug for themed widgets (matches the iOS `WidgetTemplates/<slug>/...` layout).
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
        case .photo, .staticImage, .template: return [.small, .medium, .large]
        case .polaroid:                        return [.small, .medium]
        default:                               return [.small]
        }
    }
}

// MARK: - Per-kind state (mirrors the iOS `*WidgetState` structs)

/// Photo widget: one or more user photos (rotated by the widget over time on iOS; on the desktop
/// overlay we show the first and cycle on a timer). `relativePaths` resolve against the instance's
/// asset directory.
struct PhotoWidgetState: Codable, Equatable, Sendable {
    var relativePaths: [String] = []
    /// `true` keeps the photo aspect-filled (default, like iOS); `false` fits it letterboxed.
    var fill: Bool = true
}

/// Static image widget (NEW): a single backend PNG copied into the instance directory.
struct StaticImageState: Codable, Equatable, Sendable {
    var relativePath: String = ""
    /// Slug of the catalog item it came from, for usage reporting / re-download.
    var sourceSlug: String? = nil
}

/// Polaroid carousel. Background mirrors the iOS `PolaroidWidgetState.Background`.
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

/// Shared shape for the four themed reveal widgets (elevator / opened-eyes / garage-door /
/// windows-xp). They differ only in their asset set and slide geometry, not their data.
struct ThemedToggleState: Codable, Equatable, Sendable {
    var photoRelativePath: String? = nil
    /// Closed (door/eyelid shut, photo hidden) vs open. For Windows XP this reads as "hidden".
    var isClosed: Bool = false
}

/// DIY animated widget: a template slug plus the user's photo. iOS bakes opaque frames at save
/// time; the Mac editor does the same and stores their relative paths here.
struct DIYAnimatedWidgetState: Codable, Equatable, Sendable {
    var templateSlug: String = ""
    var photoRelativePath: String? = nil
    var bakedFrameRelativePaths: [String] = []
    var coverRelativePath: String? = nil
    var isOpen: Bool = false
}

/// Backend Widgify template. `replacements` carries the dynamic text/color customizations keyed
/// by the template's `#{customize.X}` field names.
struct TemplateWidgetState: Codable, Equatable, Sendable {
    var templateSlug: String = ""
    var sizeFolder: String = "small"
    var photoRelativePath: String? = nil
    var replacements: [String: String] = [:]
    /// Animated WebP / preview asset relative path, used for the in-app + desktop render.
    var previewRelativePath: String? = nil
    /// Remote catalog thumbnail, rendered as the fallback when there's no local preview asset —
    /// so a template / unsupported backend kind (e.g. `world_cup_stats`) shows its real artwork
    /// instead of an empty placeholder.
    var thumbnailURLString: String? = nil
}

/// Discriminated payload. Swift synthesises `Codable` for enums with associated values, which is
/// all we need for local persistence.
enum WidgetPayload: Codable, Equatable, Sendable {
    case photo(PhotoWidgetState)
    case staticImage(StaticImageState)
    case polaroid(PolaroidWidgetState)
    case themed(ThemedToggleState)
    case diyAnimated(DIYAnimatedWidgetState)
    case template(TemplateWidgetState)
    // Note: the four themed kinds share `.themed`, so the payload can't identify which theme it
    // is — `WidgetInstance.kind` is the single source of truth, and all rendering/editing dispatch
    // on it. (A `payload.kind` accessor would be ambiguous for `.themed`, so it's deliberately
    // absent.)
}

// MARK: - Payload accessors

extension WidgetPayload {
    /// Photo paths for `.photo` and `.polaroid`; `nil` for all other kinds.
    var relativePaths: [String]? {
        switch self {
        case .photo(let s): return s.relativePaths
        case .polaroid(let s): return s.relativePaths
        default: return nil
        }
    }

    /// Single user photo path used by themed reveal widgets and DIY animated.
    var themedPhotoPath: String? {
        if case .themed(let s) = self { return s.photoRelativePath }
        return nil
    }

    /// Relative path for the `.staticImage` payload.
    var staticImagePath: String? {
        if case .staticImage(let s) = self { return s.relativePath.isEmpty ? nil : s.relativePath }
        return nil
    }

    /// Preview/render path for the `.template` payload.
    var templatePreviewPath: String? {
        if case .template(let s) = self { return s.previewRelativePath }
        return nil
    }

    /// Remote thumbnail URL fallback for the `.template` payload.
    var templateThumbnailURL: URL? {
        if case .template(let s) = self { return s.thumbnailURLString.flatMap(URL.init(string:)) }
        return nil
    }

    /// Whether the photo fill flag is enabled (`.photo` only; defaults to `true`).
    var photoFill: Bool {
        if case .photo(let s) = self { return s.fill }
        return true
    }
}

// MARK: - Instance

/// A user-created widget. This is the unit the gallery lists, the editors produce, and the
/// desktop manager places. Photos and baked frames live in `assetsDirectory`; the relative paths
/// inside `payload` resolve against it.
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
