import Cocoa
import AVKit
import Metal
import MetalKit

class VideoWallpaperWindow: NSWindow {
    var player: AVPlayer?
    var loopObserver: NSObjectProtocol?

    init(screen: NSScreen, videoURL: URL) {
        let frame = screen.frame

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Configure window to be at desktop level
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false

        // Setup video player
        setupVideoPlayer(videoURL: videoURL, frame: frame)
    }

    func setupVideoPlayer(videoURL: URL, frame: NSRect) {
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = frame
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let player = AVPlayer(url: videoURL)
        player.isMuted = true
        playerLayer.player = player
        self.player = player

        let containerView = NSView(frame: frame)
        containerView.wantsLayer = true
        containerView.autoresizingMask = [.width, .height]
        containerView.layer?.addSublayer(playerLayer)

        self.contentView = containerView

        // Auto-play and loop
        player.play()

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    func stop() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
    }
}

class ShaderWallpaperWindow: NSWindow {
    var renderer: ShaderRenderer?

    init(screen: NSScreen, shaderURL: URL) {
        let frame = screen.frame

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Configure window to be at desktop level
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false

        // Setup Metal shader rendering
        setupShaderRenderer(shaderURL: shaderURL, frame: frame)
    }

    func setupShaderRenderer(shaderURL: URL, frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            print("Failed to load shader or create Metal device")
            return
        }

        let metalView = MTKView(frame: frame, device: device)
        metalView.autoresizingMask = [.width, .height]

        let renderer = ShaderRenderer(device: device, shaderSource: shaderSource)
        self.renderer = renderer
        metalView.delegate = renderer

        self.contentView = metalView
    }

    func stop() {
        renderer = nil
    }
}

class ShaderRenderer: NSObject, MTKViewDelegate {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState?
    var startTime: Date = Date()

    struct Uniforms {
        var iResolution: SIMD2<Float>
        var iTime: Float
        var padding: Float // Padding to align to 16 bytes
    }

    init(device: MTLDevice, shaderSource: String) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        super.init()

        setupPipeline(shaderSource: shaderSource)
    }

    func setupPipeline(shaderSource: String) {
        // Hardcoded vertex shader - fullscreen quad
        let vertexShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct Uniforms {
            float2 iResolution;
            float iTime;
        };

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
            VertexOut out;

            // Fullscreen quad vertices
            float2 positions[6] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2(-1.0,  1.0),
                float2( 1.0, -1.0),
                float2( 1.0,  1.0)
            };

            float2 uvs[6] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(0.0, 0.0),
                float2(1.0, 1.0),
                float2(1.0, 0.0)
            };

            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }
        """

        // Combine vertex and fragment shaders
        let combinedSource = vertexShaderSource + "\n" + shaderSource

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: combinedSource, options: nil)
        } catch let error {
            print("Failed to compile shader: \(error)")
            return
        }

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            print("Failed to find shader functions")
            return
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }

    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Calculate iTime (0-300 seconds, looping)
        let elapsed = Date().timeIntervalSince(startTime)
        let iTime = Float(elapsed.truncatingRemainder(dividingBy: 300.0))

        // Setup uniforms
        var uniforms = Uniforms(
            iResolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            iTime: iTime,
            padding: 0.0
        )

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

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
    var currentRenderer: ShaderRenderer?
    var setWallpaperButton: NSButton?
    var videoWallpaperWindows: [VideoWallpaperWindow] = []
    var shaderWallpaperWindows: [ShaderWallpaperWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create assets folder
        createAssetsFolder()

        // Restore video wallpaper if needed
        restoreVideoWallpaper()

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
        let subfolders = ["Videos", "Images", "Shaders", "Animations", "FirstFrames"]
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

    func restoreVideoWallpaper() {
        guard let assetsFolderURL = assetsFolderURL else { return }

        let settingsURL = assetsFolderURL.appendingPathComponent("settings.txt")

        // Read settings.txt
        guard let wallpaperPath = try? String(contentsOf: settingsURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            print("No settings.txt found or failed to read")
            return
        }

        // Check if wallpaper is from FirstFrames folder
        guard wallpaperPath.contains("/FirstFrames/") else {
            print("Wallpaper is not from FirstFrames folder, no video/shader to restore")
            return
        }

        // Extract filename without extension
        let wallpaperURL = URL(fileURLWithPath: wallpaperPath)
        let filename = wallpaperURL.deletingPathExtension().lastPathComponent

        // Search for video with same name in Videos folder
        let videosFolder = assetsFolderURL.appendingPathComponent("Videos")
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]

        if let files = try? FileManager.default.contentsOfDirectory(at: videosFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let fileNameWithoutExt = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension.lowercased()

                if fileNameWithoutExt == filename && videoExtensions.contains(ext) {
                    print("Found matching video: \(file.path)")
                    // Restore video wallpaper
                    createVideoWallpapers(videoURL: file)
                    return
                }
            }
        }

        // Search for shader with same name in Shaders folder
        let shadersFolder = assetsFolderURL.appendingPathComponent("Shaders")
        let shaderExtensions = ["msl"]

        if let files = try? FileManager.default.contentsOfDirectory(at: shadersFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let fileNameWithoutExt = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension.lowercased()

                if fileNameWithoutExt == filename && shaderExtensions.contains(ext) {
                    print("Found matching shader: \(file.path)")
                    // Restore shader wallpaper
                    createShaderWallpapers(shaderURL: file)
                    return
                }
            }
        }

        print("No matching video or shader found for: \(filename)")
    }

    func loadRandomAssets() {
        guard let assetsFolderURL = assetsFolderURL else { return }

        let fileManager = FileManager.default
        var allAssets: [URL] = []

        let subfolders = ["Videos", "Images", "Shaders", "Animations"]
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"]
        let shaderExtensions = ["msl"]

        for subfolder in subfolders {
            let folderURL = assetsFolderURL.appendingPathComponent(subfolder)

            guard let files = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files {
                let ext = file.pathExtension.lowercased()
                if videoExtensions.contains(ext) || imageExtensions.contains(ext) || shaderExtensions.contains(ext) {
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
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let shaderExtensions = ["msl"]

        var wallpaperURL = assetURL
        let isVideo = videoExtensions.contains(ext)
        let isShader = shaderExtensions.contains(ext)

        // For videos, extract first frame
        if isVideo {
            guard let firstFrameURL = extractFirstFrame(from: assetURL) else {
                print("Failed to extract first frame")
                return
            }
            wallpaperURL = firstFrameURL
        } else if isShader {
            // For shaders, render first frame
            guard let firstFrameURL = renderFirstFrame(from: assetURL) else {
                print("Failed to render first frame")
                return
            }
            wallpaperURL = firstFrameURL
        } else if !imageExtensions.contains(ext) {
            // Not an image, video, or shader
            return
        }

        // Set static wallpaper (first frame for videos/shaders, actual image for images)
        do {
            let workspace = NSWorkspace.shared
            if let screen = NSScreen.main {
                try workspace.setDesktopImageURL(wallpaperURL, for: screen, options: [:])
                print("Wallpaper set successfully")

                // Save wallpaper path to settings.txt
                saveWallpaperPath(wallpaperURL)

                // Create animated wallpaper windows based on type
                if isVideo {
                    createVideoWallpapers(videoURL: assetURL)
                    stopShaderWallpapers()
                } else if isShader {
                    createShaderWallpapers(shaderURL: assetURL)
                    stopVideoWallpapers()
                } else {
                    // Stop any existing video or shader wallpapers when setting a static image
                    stopVideoWallpapers()
                    stopShaderWallpapers()
                }
            }
        } catch {
            print("Failed to set wallpaper: \(error)")
        }
    }

    func saveWallpaperPath(_ url: URL) {
        guard let assetsFolderURL = assetsFolderURL else { return }

        let settingsURL = assetsFolderURL.appendingPathComponent("settings.txt")
        let path = url.path

        do {
            // Overwrite file content (not append)
            try path.write(to: settingsURL, atomically: true, encoding: .utf8)
            print("Wallpaper path saved to settings.txt: \(path)")
        } catch {
            print("Failed to save wallpaper path: \(error)")
        }
    }

    func stopVideoWallpapers() {
        for window in videoWallpaperWindows {
            window.stop()
            window.close()
        }
        videoWallpaperWindows.removeAll()
        print("Stopped all video wallpapers")
    }

    func createVideoWallpapers(videoURL: URL) {
        // Stop any existing video wallpapers first
        stopVideoWallpapers()

        // Create video wallpaper window for each screen
        for screen in NSScreen.screens {
            let wallpaperWindow = VideoWallpaperWindow(screen: screen, videoURL: videoURL)
            wallpaperWindow.orderBack(nil)
            videoWallpaperWindows.append(wallpaperWindow)
        }

        print("Created video wallpaper windows for \(NSScreen.screens.count) screen(s)")
    }

    func stopShaderWallpapers() {
        for window in shaderWallpaperWindows {
            window.stop()
            window.close()
        }
        shaderWallpaperWindows.removeAll()
        print("Stopped all shader wallpapers")
    }

    func createShaderWallpapers(shaderURL: URL) {
        // Stop any existing shader wallpapers first
        stopShaderWallpapers()

        // Create shader wallpaper window for each screen
        for screen in NSScreen.screens {
            let wallpaperWindow = ShaderWallpaperWindow(screen: screen, shaderURL: shaderURL)
            wallpaperWindow.orderBack(nil)
            shaderWallpaperWindows.append(wallpaperWindow)
        }

        print("Created shader wallpaper windows for \(NSScreen.screens.count) screen(s)")
    }

    func renderFirstFrame(from shaderURL: URL) -> URL? {
        guard let assetsFolderURL = assetsFolderURL else { return nil }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) else { return nil }

        let firstFramesFolder = assetsFolderURL.appendingPathComponent("FirstFrames")
        let shaderName = shaderURL.deletingPathExtension().lastPathComponent
        let imageURL = firstFramesFolder.appendingPathComponent("\(shaderName).jpg")

        // Check if already rendered
        if FileManager.default.fileExists(atPath: imageURL.path) {
            print("First frame already exists: \(imageURL.path)")
            return imageURL
        }

        // Render one frame of the shader at 1920x1080
        let width = 1920
        let height = 1080

        // Create renderer and MTKView
        let renderer = ShaderRenderer(device: device, shaderSource: shaderSource)
        guard renderer.pipelineState != nil else {
            print("Failed to create shader pipeline")
            return nil
        }

        // Create texture to render into
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }

        // Render to texture
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }

        // Setup uniforms for time 0
        var uniforms = ShaderRenderer.Uniforms(
            iResolution: SIMD2<Float>(Float(width), Float(height)),
            iTime: 0.0,
            padding: 0.0
        )

        renderEncoder.setRenderPipelineState(renderer.pipelineState!)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderRenderer.Uniforms>.size, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Convert texture to image
        guard let image = textureToNSImage(texture: texture, width: width, height: height) else {
            return nil
        }

        // Save as JPEG
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            return nil
        }

        do {
            try jpegData.write(to: imageURL)
            print("Rendered first frame: \(imageURL.path)")
            return imageURL
        } catch {
            print("Failed to save rendered frame: \(error)")
            return nil
        }
    }

    func textureToNSImage(texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let rowBytes = width * 4
        let imageBytes = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 1)
        defer { imageBytes.deallocate() }

        texture.getBytes(imageBytes, bytesPerRow: rowBytes, from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1)), mipmapLevel: 0)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)

        guard let context = CGContext(data: imageBytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    func extractFirstFrame(from videoURL: URL) -> URL? {
        guard let assetsFolderURL = assetsFolderURL else { return nil }

        let firstFramesFolder = assetsFolderURL.appendingPathComponent("FirstFrames")
        let videoName = videoURL.deletingPathExtension().lastPathComponent
        let imageURL = firstFramesFolder.appendingPathComponent("\(videoName).jpg")

        // Check if already extracted
        if FileManager.default.fileExists(atPath: imageURL.path) {
            print("First frame already exists: \(imageURL.path)")
            return imageURL
        }

        // Extract first frame
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        do {
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            // Save as JPEG
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                print("Failed to convert image to JPEG")
                return nil
            }

            try jpegData.write(to: imageURL)
            print("First frame saved to: \(imageURL.path)")
            return imageURL

        } catch {
            print("Failed to extract first frame: \(error)")
            return nil
        }
    }

    func loadAssetAtIndex(_ index: Int) {
        guard index >= 0 && index < homeAssets.count else { return }
        guard let mediaContainerView = mediaContainerView else { return }

        // Stop and remove current player
        currentPlayer?.pause()
        currentPlayer = nil
        currentRenderer = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

        // Remove existing media views
        mediaContainerView.subviews.forEach { $0.removeFromSuperview() }

        let assetURL = homeAssets[index]
        let ext = assetURL.pathExtension.lowercased()

        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"]
        let shaderExtensions = ["msl"]

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
        } else if shaderExtensions.contains(ext) {
            // Load shader
            guard let device = MTLCreateSystemDefaultDevice(),
                  let shaderSource = try? String(contentsOf: assetURL, encoding: .utf8) else {
                return
            }

            let metalView = MTKView(frame: mediaContainerView.bounds, device: device)
            metalView.autoresizingMask = [.width, .height]

            let renderer = ShaderRenderer(device: device, shaderSource: shaderSource)
            currentRenderer = renderer
            metalView.delegate = renderer

            mediaContainerView.addSubview(metalView)
        }

        // Enable/disable wallpaper button based on asset type (works for images, videos, and shaders)
        setWallpaperButton?.isEnabled = imageExtensions.contains(ext) || videoExtensions.contains(ext) || shaderExtensions.contains(ext)

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
