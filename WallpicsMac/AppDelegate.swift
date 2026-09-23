import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        startPetMonitoring()

        // Bring back the last live/shader wallpaper after a relaunch (e.g. login/restart), so it
        // keeps running instead of leaving the low-res still on the desktop. Paired with the
        // optional Login Item so the app actually relaunches.
        WallpaperRenderer.shared.restoreLast()

        DesktopWidgetManager.shared.restoreAll()
        DesktopPetManager.shared.restoreAll()
        Task {
            await RemotePetService.shared.refresh()
            if !DesktopPetManager.shared.isRunning {
                DesktopPetManager.shared.restoreAll()
                PetBackdropService.shared.reapply()
            }
        }
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
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildStatusMenu(menu)
        updateStatusBadge()
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuildStatusMenu(menu) }
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: String(localized: "Show WallPics"), action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        let diyItems = diyMenuItems()
        if !diyItems.isEmpty {
            diyItems.forEach(menu.addItem)
            menu.addItem(NSMenuItem.separator())
        }
        menu.addItem(NSMenuItem(title: String(localized: "Pause Wallpaper"), action: #selector(togglePause), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: String(localized: "Pause Pets"), action: #selector(togglePetPause), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit WallPics"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func diyMenuItems() -> [NSMenuItem] {
        let store = PetSubmissionStore.shared
        let pending = store.inReview
        let ready = Array(store.ready.prefix(Self.maxReadyMenuItems))
        guard !pending.isEmpty || !ready.isEmpty else { return [] }

        var items: [NSMenuItem] = [NSMenuItem.sectionHeader(title: String(localized: "DIY Pets"))]
        for record in ready {
            let item = NSMenuItem(title: String(localized: "Put \(record.name) on Desktop"),
                                  action: #selector(placeReadyPet(_:)), keyEquivalent: "")
            item.representedObject = record.id
            item.image = NSImage(systemSymbolName: record.readySeen ? "pawprint.fill" : "sparkles",
                                 accessibilityDescription: nil)
            items.append(item)
        }
        for record in pending {
            let item = NSMenuItem(title: String(localized: "\(record.name) — in review"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
            items.append(item)
        }
        if !pending.isEmpty {
            let sync = PetSubmissionSync.shared
            let check = NSMenuItem(title: sync.isChecking ? String(localized: "Checking…") : String(localized: "Check Status Now"),
                                   action: sync.isChecking ? nil : #selector(checkDIYStatus), keyEquivalent: "")
            check.isEnabled = !sync.isChecking
            items.append(check)
            if let error = sync.lastError {
                let failed = NSMenuItem(title: error, action: nil, keyEquivalent: "")
                failed.isEnabled = false
                failed.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                items.append(failed)
            }
        }
        return items
    }

    private static let maxReadyMenuItems = 5

    private func startPetMonitoring() {
        PetSubmissionSync.shared.start()
        NotificationCenter.default.addObserver(
            forName: PetSubmissionStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusBadge() }
        }
        NotificationCenter.default.addObserver(
            forName: PetReadyCenter.openDIYRequest, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showMainWindow()
                AppEnvironment.shared.selectedSection = .diy
            }
        }
        updateStatusBadge()
    }

    private func updateStatusBadge() {
        guard let button = statusItem?.button else { return }
        switch PetSubmissionStore.shared.menuState {
        case .ready(let count):
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " ●", attributes: [
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .baselineOffset: 1
            ])
            button.toolTip = String(localized: "\(count) DIY pet(s) ready")
        case .waiting(let count):
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = String(localized: "\(count) DIY pet(s) in review")
        case .idle:
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "WallPics"
        }
    }

    @objc private func placeReadyPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = PetSubmissionStore.shared.ready.first(where: { $0.id == id }) else { return }
        PetSubmissionStore.shared.markReadySeen(ids: [id])
        guard let species = record.catalogSlug.flatMap(PetCatalog.species(slug:)) else {
            showMainWindow()
            AppEnvironment.shared.selectedSection = .diy
            return
        }
        if !PetDesktopActions.place(species) {
            showMainWindow()
        }
    }

    @objc private func checkDIYStatus() {
        PetSubmissionSync.shared.refreshNow(force: true)
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
