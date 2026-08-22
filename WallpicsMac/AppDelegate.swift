import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var settings = AppSettings.load()
    private var mainWindowController: MainWindowController?
    private var statusItem: NSStatusItem?
    private var powerMonitor: PowerMonitor?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { self.bootstrap() }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { self.teardown() }
    }

    /// Always allow termination immediately. Without this, a logout/restart/shutdown that
    /// arrives while a sheet (e.g. the paywall) or the status-bar-only state is up can stall —
    /// macOS then shows "WallpicsMac interrupted shutdown. To continue, quit WallpicsMac." We
    /// hold no unsaved documents (settings/favorites are written as they change), so quitting
    /// now is always safe.
    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // Restore whether the window was closed, minimized, or just hidden behind other apps.
            mainWindowController?.reopen()
            return true
        }
    }

    private func bootstrap() {
        // Let macOS fast-quit us during logout/restart/shutdown without waiting on the run loop.
        // Safe here: all user state is persisted at mutation time, nothing is buffered to flush.
        ProcessInfo.processInfo.enableSuddenTermination()

        // Apply the saved language preference (affects AppKit chrome + next launch).
        LanguageController.apply(AppEnvironment.shared.settings.languageCode)

        if settings.respectSystemAppearance {
            NSApp.appearance = nil
        } else {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // Re-apply the pause policy whenever a playback setting changes in the UI.
        NotificationCenter.default.addObserver(
            forName: .reapplyPowerState, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.powerMonitor else { return }
                self.handlePowerChange(source: m.currentSource, lowPower: m.isLowPowerMode)
            }
        }

        StoreKitService.shared.bootstrap()
        CrashReporter.shared.register()

        let cacheEnabled = settings.cacheRecentWallpapers
        Task { await CacheManager.shared.startPeriodicSweep(cacheEnabled: cacheEnabled) }

        let monitor = PowerMonitor()
        monitor.onChange = { [weak self] source, lowPower in
            self?.handlePowerChange(source: source, lowPower: lowPower)
        }
        monitor.start()
        powerMonitor = monitor
        // Apply the current power state immediately so a launch on battery respects the
        // setting without waiting for the first power-source change.
        handlePowerChange(source: monitor.currentSource, lowPower: monitor.isLowPowerMode)

        installMainMenu()

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        installStatusItem()

        // Bring back the last live/shader wallpaper after a relaunch (e.g. login/restart), so it
        // keeps running instead of leaving the low-res still on the desktop. Paired with the
        // optional Login Item so the app actually relaunches.
        WallpaperRenderer.shared.restoreLast()

        DesktopWidgetManager.shared.restoreAll()
        DesktopPetManager.shared.restoreAll()
        PetBackdropService.shared.reapply()
        WidgetSharedExport.sync()
        // Publish the backend widget gallery to the App Group so the native macOS picker lists
        // every WallPics widget, not just ones the user created.
        Task { await WidgetSharedExport.refreshCatalog() }

        // Onboarding presentation is now driven from ContentView .task — it triggers the
        // sheet only after the main window mounts, so the user sees it on top of the app.
    }

    private func teardown() {
        Task { await CacheManager.shared.stopPeriodicSweep() }
        powerMonitor?.stop()
        WallpaperRenderer.shared.clear()
    }

    // MARK: - Power handling

    private func handlePowerChange(source: PowerMonitor.Source, lowPower: Bool) {
        // Read the live settings (the UI mutates AppEnvironment.shared, not our launch copy).
        let settings = AppEnvironment.shared.settings
        let renderer = WallpaperRenderer.shared
        renderer.setPaused(!settings.playOnBatteryPower && source == .battery, reason: .onBattery)
        renderer.setPaused(settings.pauseOnLowPowerMode && lowPower, reason: .lowPower)

        let pets = DesktopPetManager.shared
        pets.setPaused(false, reason: .onBattery)
        pets.setPaused(false, reason: .lowPower)
    }

    // MARK: - Main menu

    /// This app is launched programmatically (no MainMenu nib), so AppKit installs no menu bar
    /// by default — which means ⌘Q, ⌘W, and clipboard shortcuts in text fields silently do
    /// nothing. Build a standard menu so the app behaves like a normal Mac app.
    private func installMainMenu() {
        let appName = "WallPics"
        let mainMenu = NSMenu()

        // Application menu (the bold one named after the app). Holds Quit (⌘Q).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu — gives the search field and any text input the standard clipboard shortcuts.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Window menu — Minimize (⌘M) and Close (⌘W).
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Palm tree from the app icon, rendered as a monochrome template so it adapts to
            // the menu bar (light/dark) like the other status items.
            let icon = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "WallPics")
            icon?.isTemplate = true
            button.image = icon
            button.image?.accessibilityDescription = "WallPics"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show WallPics", action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Pause Wallpaper", action: #selector(togglePause), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Pause Pets", action: #selector(togglePetPause), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit WallPics", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
    }

    @objc private func togglePause() {
        let renderer = WallpaperRenderer.shared
        renderer.setPaused(!renderer.isPaused, reason: .userToggle)
    }

    @objc private func togglePetPause() {
        DesktopPetManager.shared.toggleUserPause()
    }
}
