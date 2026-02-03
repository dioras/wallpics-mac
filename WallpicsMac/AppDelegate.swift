import Cocoa
import AVKit

class KeyHandlingView: NSView {
    var onLeftArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            onLeftArrow?()
        case 124: // Right arrow
            onRightArrow?()
        default:
            super.keyDown(with: event)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var statusItem: NSStatusItem?
    var assetsFolderURL: URL?

    var contentContainer: NSView?
    var homeView: NSView?
    var browserView: NSView?
    var createView: NSView?
    var segmentedControl: NSSegmentedControl?

    var homeAssets: [URL] = []
    var currentAssetIndex: Int = 0
    var mediaContainerView: NSView?
    var dotsContainer: NSView?
    var prevButton: NSButton?
    var nextButton: NSButton?
    var currentPlayer: AVPlayer?
    var setWallpaperButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create assets folder
        createAssetsFolder()

        // Create the main window
        createMainWindow()

        // Create the menu bar (tray) icon
        createMenuBarIcon()

        // Show window on launch
        window?.makeKeyAndOrderFront(nil)
    }

    func createAssetsFolder() {
        let fileManager = FileManager.default

        // Get Application Support directory
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("Could not find Application Support directory")
            return
        }

        // Create WallpicsMac folder path
        assetsFolderURL = appSupportURL.appendingPathComponent("WallpicsMac")

        guard let folderURL = assetsFolderURL else { return }

        // Create directory if it doesn't exist
        ensureFolderExists(at: folderURL)

        // Create required subfolders
        let subfolders = ["Videos", "Images", "Shaders", "Animations"]
        for subfolder in subfolders {
            let subfolderURL = folderURL.appendingPathComponent(subfolder)
            ensureFolderExists(at: subfolderURL)
        }
    }

    func ensureFolderExists(at url: URL) {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                print("Created folder at: \(url.path)")
            } catch {
                print("Failed to create folder at \(url.path): \(error)")
            }
        } else {
            print("Folder already exists at: \(url.path)")
        }
    }

    func loadRandomAssets() {
        guard let assetsFolderURL = assetsFolderURL else { return }

        let fileManager = FileManager.default
        var allAssets: [URL] = []

        let subfolders = ["Videos", "Images", "Shaders", "Animations"]
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"]

        for subfolder in subfolders {
            let folderURL = assetsFolderURL.appendingPathComponent(subfolder)

            guard let files = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files {
                let ext = file.pathExtension.lowercased()
                if videoExtensions.contains(ext) || imageExtensions.contains(ext) {
                    allAssets.append(file)
                }
            }
        }

        // Shuffle and take up to 10
        homeAssets = Array(allAssets.shuffled().prefix(10))
        currentAssetIndex = 0

        print("Loaded \(homeAssets.count) random assets")
    }

    func createMainWindow() {
        // Get main screen dimensions
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Calculate 90% of screen width and height
        let windowWidth = screenFrame.width * 0.9
        let windowHeight = screenFrame.height * 0.9

        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window?.title = "WallpicsMac"
        window?.center()

        // Make title bar transparent, keep buttons visible
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden

        // Adjust window buttons position and spacing
        let buttonVerticalOffset: CGFloat = 5
        let buttonHorizontalOffset: CGFloat = 10
        let spacingMultiplier: CGFloat = 1.1

        if let closeButton = window?.standardWindowButton(.closeButton),
           let miniaturizeButton = window?.standardWindowButton(.miniaturizeButton),
           let zoomButton = window?.standardWindowButton(.zoomButton) {

            let originalSpacing = miniaturizeButton.frame.origin.x - closeButton.frame.origin.x
            let newSpacing = originalSpacing * spacingMultiplier

            // Move close button
            closeButton.frame.origin.y -= buttonVerticalOffset
            closeButton.frame.origin.x += buttonHorizontalOffset

            // Move miniaturize button
            miniaturizeButton.frame.origin.y -= buttonVerticalOffset
            miniaturizeButton.frame.origin.x = closeButton.frame.origin.x + newSpacing

            // Move zoom button
            zoomButton.frame.origin.y -= buttonVerticalOffset
            zoomButton.frame.origin.x = miniaturizeButton.frame.origin.x + newSpacing
        }

        // Keep window in memory when closed
        window?.isReleasedWhenClosed = false

        // Prevent app from quitting when window is closed
        window?.delegate = self

        // Setup the window content
        setupWindowContent(frame: contentRect)

        // Enable key events for arrow navigation
        window?.makeFirstResponder(window?.contentView)
    }

    func setupWindowContent(frame: NSRect) {
        guard let window = window else { return }

        // Main container view with keyboard handling
        let mainView = KeyHandlingView(frame: frame)
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Set up keyboard shortcuts
        mainView.onLeftArrow = { [weak self] in
            self?.previousAsset()
        }
        mainView.onRightArrow = { [weak self] in
            self?.nextAsset()
        }

        window.contentView = mainView

        // Create segmented control for navigation
        let segmentedControlWidth: CGFloat = 300
        let segmentedControlHeight: CGFloat = 28

        // Get the actual position of the close button to align with it
        var segmentedControlY: CGFloat = frame.height - 40
        if let closeButton = window.standardWindowButton(.closeButton),
           let buttonSuperview = closeButton.superview {
            // Convert close button position to mainView coordinates
            let closeButtonFrame = buttonSuperview.convert(closeButton.frame, to: mainView)
            let closeButtonCenterY = closeButtonFrame.midY
            segmentedControlY = closeButtonCenterY - (segmentedControlHeight / 2)
        }

        // Center horizontally
        let segmentedControlX = (frame.width - segmentedControlWidth) / 2

        segmentedControl = NSSegmentedControl(frame: NSRect(
            x: segmentedControlX,
            y: segmentedControlY,
            width: segmentedControlWidth,
            height: segmentedControlHeight
        ))
        segmentedControl?.segmentCount = 3
        segmentedControl?.setLabel("Home", forSegment: 0)
        segmentedControl?.setLabel("Browser", forSegment: 1)
        segmentedControl?.setLabel("Create", forSegment: 2)
        segmentedControl?.selectedSegment = 0
        segmentedControl?.target = self
        segmentedControl?.action = #selector(segmentChanged(_:))
        segmentedControl?.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

        // Content container (below the segmented control)
        let containerY: CGFloat = 0
        let containerHeight = frame.height
        contentContainer = NSView(frame: NSRect(x: 0, y: containerY, width: frame.width, height: containerHeight))
        contentContainer?.wantsLayer = true

        if let contentContainer = contentContainer {
            mainView.addSubview(contentContainer)
        }

        // Add segmented control ABOVE content container
        if let segmentedControl = segmentedControl {
            mainView.addSubview(segmentedControl, positioned: .above, relativeTo: contentContainer)
        }

        // Load random assets for home screen
        loadRandomAssets()

        // Create the three views
        createHomeView(frame: contentContainer?.bounds ?? .zero)
        createBrowserView(frame: contentContainer?.bounds ?? .zero)
        createCreateView(frame: contentContainer?.bounds ?? .zero)

        // Show home view by default
        showView(homeView)
    }

    func createHomeView(frame: NSRect) {
        homeView = NSView(frame: frame)
        homeView?.wantsLayer = true
        homeView?.autoresizingMask = [.width, .height]

        guard let homeView = homeView else { return }

        // Check if we have assets
        if homeAssets.isEmpty {
            // Show "No data" message
            let textField = NSTextField(labelWithString: "No data")
            textField.font = NSFont.systemFont(ofSize: 48, weight: .medium)
            textField.textColor = .labelColor
            textField.alignment = .center
            textField.frame = NSRect(x: 0, y: frame.height / 2 - 30, width: frame.width, height: 60)
            textField.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            homeView.addSubview(textField)
            return
        }

        // Create carousel UI
        let buttonWidth: CGFloat = 50

        // Media container (full frame, behind all controls)
        mediaContainerView = NSView(frame: frame)
        mediaContainerView?.wantsLayer = true
        mediaContainerView?.layer?.masksToBounds = true
        mediaContainerView?.autoresizingMask = [.width, .height]
        if let mediaContainerView = mediaContainerView {
            homeView.addSubview(mediaContainerView)
        }

        // Previous button (left, vertically centered)
        prevButton = NSButton(frame: NSRect(
            x: 10,
            y: (frame.height - buttonWidth) / 2,
            width: buttonWidth,
            height: buttonWidth
        ))
        prevButton?.title = "<"
        prevButton?.bezelStyle = .circular
        prevButton?.target = self
        prevButton?.action = #selector(previousAsset)
        prevButton?.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        if let prevButton = prevButton {
            homeView.addSubview(prevButton, positioned: .above, relativeTo: mediaContainerView)
        }

        // Next button (right, vertically centered)
        nextButton = NSButton(frame: NSRect(
            x: frame.width - buttonWidth - 10,
            y: (frame.height - buttonWidth) / 2,
            width: buttonWidth,
            height: buttonWidth
        ))
        nextButton?.title = ">"
        nextButton?.bezelStyle = .circular
        nextButton?.target = self
        nextButton?.action = #selector(nextAsset)
        nextButton?.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        if let nextButton = nextButton {
            homeView.addSubview(nextButton, positioned: .above, relativeTo: mediaContainerView)
        }

        // Set as wallpaper button (above dots, centered)
        let wallpaperButtonWidth: CGFloat = 160
        let wallpaperButtonHeight: CGFloat = 28
        setWallpaperButton = NSButton(frame: NSRect(
            x: (frame.width - wallpaperButtonWidth) / 2,
            y: 60,
            width: wallpaperButtonWidth,
            height: wallpaperButtonHeight
        ))
        setWallpaperButton?.title = "Set as a wallpaper"
        setWallpaperButton?.bezelStyle = .rounded
        setWallpaperButton?.font = NSFont.systemFont(ofSize: 13)
        setWallpaperButton?.target = self
        setWallpaperButton?.action = #selector(setAsWallpaper)
        setWallpaperButton?.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        if let setWallpaperButton = setWallpaperButton {
            homeView.addSubview(setWallpaperButton, positioned: .above, relativeTo: mediaContainerView)
        }

        // Dots container (bottom, centered)
        let dotSpacing: CGFloat = 25
        let dotsWidth = CGFloat(homeAssets.count) * dotSpacing
        let dotsHeight: CGFloat = 30
        dotsContainer = NSView(frame: NSRect(
            x: (frame.width - dotsWidth) / 2,
            y: 10,
            width: dotsWidth,
            height: dotsHeight
        ))
        dotsContainer?.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        if let dotsContainer = dotsContainer {
            homeView.addSubview(dotsContainer, positioned: .above, relativeTo: mediaContainerView)
        }

        // Create dots
        createDots()

        // Load first asset
        loadAssetAtIndex(currentAssetIndex)
    }

    func createDots() {
        guard let dotsContainer = dotsContainer else { return }

        // Remove existing dots
        dotsContainer.subviews.forEach { $0.removeFromSuperview() }

        // Create dot buttons
        let dotSize: CGFloat = 8
        let dotSpacing: CGFloat = 25

        for i in 0..<homeAssets.count {
            let dotView = NSView(frame: NSRect(
                x: CGFloat(i) * dotSpacing + (dotSpacing - dotSize) / 2,
                y: (30 - dotSize) / 2,
                width: dotSize,
                height: dotSize
            ))
            dotView.wantsLayer = true
            dotView.layer?.cornerRadius = dotSize / 2
            dotView.layer?.backgroundColor = NSColor.gray.cgColor

            // Add click gesture
            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(dotClicked(_:)))
            dotView.addGestureRecognizer(clickGesture)

            dotsContainer.addSubview(dotView)
        }

        updateDots()
    }

    func updateDots() {
        guard let dotsContainer = dotsContainer else { return }

        for (index, subview) in dotsContainer.subviews.enumerated() {
            if index == currentAssetIndex {
                subview.layer?.backgroundColor = NSColor.white.cgColor
            } else {
                subview.layer?.backgroundColor = NSColor.gray.cgColor
            }
        }
    }

    @objc func setAsWallpaper() {
        guard currentAssetIndex >= 0 && currentAssetIndex < homeAssets.count else { return }

        let assetURL = homeAssets[currentAssetIndex]
        let ext = assetURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"]

        // Only set wallpaper for images
        guard imageExtensions.contains(ext) else { return }

        do {
            let workspace = NSWorkspace.shared
            if let screen = NSScreen.main {
                try workspace.setDesktopImageURL(assetURL, for: screen, options: [:])
                print("Wallpaper set successfully")
            }
        } catch {
            print("Failed to set wallpaper: \(error)")
        }
    }

    func loadAssetAtIndex(_ index: Int) {
        guard index >= 0 && index < homeAssets.count else { return }
        guard let mediaContainerView = mediaContainerView else { return }

        // Stop and remove current player
        currentPlayer?.pause()
        currentPlayer = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

        // Remove existing media views
        mediaContainerView.subviews.forEach { $0.removeFromSuperview() }

        let assetURL = homeAssets[index]
        let ext = assetURL.pathExtension.lowercased()

        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"]

        if videoExtensions.contains(ext) {
            // Load video - create layer to properly fill view
            let playerLayer = AVPlayerLayer()
            playerLayer.frame = mediaContainerView.bounds
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

            let player = AVPlayer(url: assetURL)
            player.isMuted = true
            playerLayer.player = player
            currentPlayer = player

            let containerView = NSView(frame: mediaContainerView.bounds)
            containerView.wantsLayer = true
            containerView.autoresizingMask = [.width, .height]
            containerView.layer?.addSublayer(playerLayer)

            mediaContainerView.addSubview(containerView)

            // Auto-play and loop
            player.play()

            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                player.seek(to: .zero)
                player.play()
            }

        } else if imageExtensions.contains(ext) {
            // Load image - fill entire view properly
            if let image = NSImage(contentsOf: assetURL) {
                let containerView = NSView(frame: mediaContainerView.bounds)
                containerView.wantsLayer = true
                containerView.autoresizingMask = [.width, .height]

                // Set layer contents with aspect fill gravity
                containerView.layer?.contents = image
                containerView.layer?.contentsGravity = .resizeAspectFill

                mediaContainerView.addSubview(containerView)
            }
        }

        // Enable/disable wallpaper button based on asset type
        setWallpaperButton?.isEnabled = imageExtensions.contains(ext)

        updateDots()
    }

    @objc func previousAsset() {
        if homeAssets.isEmpty { return }
        currentAssetIndex = (currentAssetIndex - 1 + homeAssets.count) % homeAssets.count
        loadAssetAtIndex(currentAssetIndex)
    }

    @objc func nextAsset() {
        if homeAssets.isEmpty { return }
        currentAssetIndex = (currentAssetIndex + 1) % homeAssets.count
        loadAssetAtIndex(currentAssetIndex)
    }

    @objc func dotClicked(_ sender: NSClickGestureRecognizer) {
        guard let dotView = sender.view,
              let dotsContainer = dotsContainer,
              let index = dotsContainer.subviews.firstIndex(of: dotView) else {
            return
        }

        currentAssetIndex = index
        loadAssetAtIndex(currentAssetIndex)
    }

    func createBrowserView(frame: NSRect) {
        browserView = NSView(frame: frame)
        browserView?.wantsLayer = true
        browserView?.autoresizingMask = [.width, .height]

        // Add centered text
        let textField = NSTextField(labelWithString: "Browser")
        textField.font = NSFont.systemFont(ofSize: 48, weight: .medium)
        textField.textColor = .labelColor
        textField.alignment = .center
        textField.frame = NSRect(x: 0, y: frame.height / 2 - 30, width: frame.width, height: 60)
        textField.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        browserView?.addSubview(textField)
    }

    func createCreateView(frame: NSRect) {
        createView = NSView(frame: frame)
        createView?.wantsLayer = true
        createView?.autoresizingMask = [.width, .height]

        // Add centered text
        let textField = NSTextField(labelWithString: "Create")
        textField.font = NSFont.systemFont(ofSize: 48, weight: .medium)
        textField.textColor = .labelColor
        textField.alignment = .center
        textField.frame = NSRect(x: 0, y: frame.height / 2 - 30, width: frame.width, height: 60)
        textField.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        createView?.addSubview(textField)
    }

    func showView(_ view: NSView?) {
        // Remove all current subviews
        contentContainer?.subviews.forEach { $0.removeFromSuperview() }

        // Add the selected view
        if let view = view {
            contentContainer?.addSubview(view)
        }
    }

    @objc func segmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            showView(homeView)
        case 1:
            showView(browserView)
        case 2:
            showView(createView)
        default:
            break
        }
    }

    func createMenuBarIcon() {
        // Create status bar item (menu bar icon)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "WallpicsMac")
        }

        // Create menu
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open WallpicsMac", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let openFolderItem = NSMenuItem(title: "Open Assets Folder", action: #selector(openAssetsFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(NSMenuItem.separator())

        let exitItem = NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "")
        exitItem.target = self
        menu.addItem(exitItem)

        statusItem?.menu = menu
    }

    @objc func openWindow() {
        if window == nil {
            createMainWindow()
        }

        // Show app in Dock when window is opened
        NSApp.setActivationPolicy(.regular)

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openAssetsFolder() {
        guard let folderURL = assetsFolderURL else {
            print("Assets folder URL not set")
            return
        }

        // Open folder in Finder
        NSWorkspace.shared.open(folderURL)
    }

    @objc func exitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Return false so app continues running when window is closed
        return false
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Hide app from Dock when window is closed (keep only in menu bar)
        NSApp.setActivationPolicy(.accessory)
    }
}
