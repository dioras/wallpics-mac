import Foundation
import Observation

extension Notification.Name {
    /// Posted when a playback setting changes so the renderer re-evaluates its pause policy.
    static let reapplyPowerState = Notification.Name("app.wallpics.reapplyPowerState")
}

@Observable
final class AppEnvironment {
    @MainActor static let shared = AppEnvironment()

    var settings: AppSettings = .load() {
        didSet { settings.save() }
    }

    var selectedSection: Section = .browse
    var selectedWallpaper: Wallpaper?
    var detailWallpaper: Wallpaper?
    var widgetEditRequestID: UUID?

    // Sheet presentation flags. Driven from anywhere via AppEnvironment.shared.
    var showOnboarding = false
    var showPaywall = false
    /// One-time alert offering to add WallPics to Login Items (set after the first wallpaper).
    var showAutostartPrompt = false

    enum Section: String, CaseIterable, Identifiable {
        case favorites, browse, uploads, widgets, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .favorites: return String(localized: "Favorites")
            case .browse: return String(localized: "Browse")
            case .uploads: return String(localized: "Uploads")
            case .widgets: return String(localized: "Widgets")
            case .settings: return String(localized: "Settings")
            }
        }
        var symbol: String {
            switch self {
            case .favorites: return "star.fill"
            case .browse: return "square.grid.2x2"
            case .uploads: return "arrow.up.square.fill"
            case .widgets: return "square.grid.3x3.fill.square"
            case .settings: return "gearshape"
            }
        }
    }

    private init() {}
}
