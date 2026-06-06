import Foundation
import ServiceManagement

/// Registers WallPics as a macOS **Login Item** so it relaunches automatically at login and the
/// live/shader wallpaper keeps playing — instead of dying when the app isn't running and leaving
/// only the static first-frame on the desktop.
///
/// Uses `SMAppService.mainApp` (macOS 13+), which works under the App Sandbox and shows up in
/// System Settings → General → Login Items. No helper bundle or extra entitlement required.
@MainActor
enum LoginItemService {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// True when WallPics is set to open at login (and the user hasn't disabled it in System Settings).
    static var isEnabled: Bool { status == .enabled }

    /// Register as a login item. Returns false if the system refused (e.g. a debug build that
    /// isn't properly signed) so callers can fall back gracefully.
    @discardableResult
    static func enable() -> Bool {
        guard status != .enabled else { return true }
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            Log.app.error("Login item register failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    static func disable() -> Bool {
        guard status == .enabled || status == .requiresApproval else { return true }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            Log.app.error("Login item unregister failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
