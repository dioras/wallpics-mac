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

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag { mainWindowController?.showWindow(nil) }
            return true
        }
    }

    private func bootstrap() {
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

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        installStatusItem()

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
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "WallPics")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show WallPics", action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Pause Wallpaper", action: #selector(togglePause), keyEquivalent: "p"))
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
}
