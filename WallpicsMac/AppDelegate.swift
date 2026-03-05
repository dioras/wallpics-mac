import Cocoa
import AVKit
import AVFoundation
import Metal
import MetalKit
import RiveRuntime
import UniformTypeIdentifiers
import CommonCrypto

// Configuration
private let maxHomeScreenAssets = 10
private let audioMuteRetryCount = 5

class GIFWallpaperWindow: NSWindow {
    var imageView: NSImageView?

    init(screen: NSScreen, gifURL: URL) {
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

        // Setup GIF animation
        setupGIFAnimation(gifURL: gifURL, frame: frame)
    }

    func setupGIFAnimation(gifURL: URL, frame: NSRect) {
        guard let image = NSImage(contentsOf: gifURL) else { return }

        // Calculate aspect fill frame
        let imageSize = image.size
        let viewSize = frame.size
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        var scaledFrame = frame
        if imageAspect > viewAspect {
            // Image is wider - fit height and crop width
            let scaledWidth = viewSize.height * imageAspect
            scaledFrame = NSRect(
                x: (viewSize.width - scaledWidth) / 2,
                y: 0,
                width: scaledWidth,
                height: viewSize.height
            )
        } else {
            // Image is taller - fit width and crop height
            let scaledHeight = viewSize.width / imageAspect
            scaledFrame = NSRect(
                x: 0,
                y: (viewSize.height - scaledHeight) / 2,
                width: viewSize.width,
                height: scaledHeight
            )
        }

        let imageView = NSImageView(frame: scaledFrame)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.image = image

        // Container to clip overflow
        let containerView = NSView(frame: frame)
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true
        containerView.addSubview(imageView)

        self.imageView = imageView
        self.contentView = containerView
    }

    func pause() {
        imageView?.animates = false
    }

    func resume() {
        imageView?.animates = true
    }

    func stop() {
        imageView?.image = nil
        imageView = nil
    }
}

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

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
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

    func pause() {
        renderer?.pause()
    }

    func resume() {
        renderer?.resume()
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
    var isPaused: Bool = false
    var pausedTime: Float = 0.0

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

    func pause() {
        // Save current time and pause
        let elapsed = Date().timeIntervalSince(startTime)
        pausedTime = Float(elapsed.truncatingRemainder(dividingBy: 300.0))
        isPaused = true
    }

    func resume() {
        // Resume from paused time
        isPaused = false
        startTime = Date().addingTimeInterval(-Double(pausedTime))
    }

    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Calculate iTime - use frozen time if paused
        let iTime: Float
        if isPaused {
            iTime = pausedTime
        } else {
            let elapsed = Date().timeIntervalSince(startTime)
            iTime = Float(elapsed.truncatingRemainder(dividingBy: 300.0))
        }

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

class AnimationWallpaperWindow: NSWindow {
    var riveViewModel: RiveViewModel?

    init(screen: NSScreen, animationURL: URL) {
        let frame = screen.frame

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false

        setupRiveAnimation(animationURL: animationURL, frame: frame)
    }

    func setupRiveAnimation(animationURL: URL, frame: NSRect) {
        let viewModel = RiveViewModel(
            webURL: animationURL.absoluteString,
            fit: .fill,
            alignment: .center,
            loadCdn: false
        )
        riveViewModel = viewModel

        let riveView = viewModel.createRiveView()
        riveView.frame = frame
        riveView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        riveView.wantsLayer = true // Essential for layer-based capture

        self.contentView = riveView

        // Start playing
        viewModel.play(loop: RiveLoop.loop)

        // Set volume to 0 multiple times with delays
        for i in 0...audioMuteRetryCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak viewModel] in
                viewModel?.riveModel?.volume = 0.0
            }
        }
    }

    func pause() {
        riveViewModel?.pause()
    }

    func resume() {
        riveViewModel?.play(loop: RiveLoop.loop)
    }

    func stop() {
        riveViewModel?.stop()
        riveViewModel = nil
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

class HoverScaleView: NSView {
    static var playButtonImage: NSImage?
    var playButtonView: NSImageView?
    var isMouseInside = false
    var wallpaperId: Int?
    var clickGesture: NSClickGestureRecognizer?

    static func createPlayButtonImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        // Draw circle background (31, 31, 31) - no transparency
        // Inset by 1 pixel to keep the 2px stroke within bounds
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2))
        NSColor(red: 31/255.0, green: 31/255.0, blue: 31/255.0, alpha: 1.0).setFill()
        circlePath.fill()

        // Draw 2 pixel border (45, 45, 45)
        NSColor(red: 45/255.0, green: 45/255.0, blue: 45/255.0, alpha: 1.0).setStroke()
        circlePath.lineWidth = 2
        circlePath.stroke()

        // Draw equilateral white triangle (play icon) with rounded corners, pointing right
        let triangleSize: CGFloat = size * 0.315 // 10% smaller than 0.35
        let centerX = size / 2 + size * 0.03 // Slightly offset to right
        let centerY = size / 2
        let height = triangleSize * sqrt(3.0) / 2.0

        // Calculate equilateral triangle points (vertical left side, pointing right)
        let p1 = NSPoint(x: centerX - height / 2, y: centerY + triangleSize / 2)  // Top left
        let p2 = NSPoint(x: centerX - height / 2, y: centerY - triangleSize / 2)  // Bottom left
        let p3 = NSPoint(x: centerX + height / 2, y: centerY)                      // Right point

        let trianglePath = NSBezierPath()
        trianglePath.move(to: p1)
        trianglePath.line(to: p2)
        trianglePath.line(to: p3)
        trianglePath.close()
        trianglePath.lineJoinStyle = .round
        trianglePath.lineCapStyle = .round

        // Add stroke to create rounded corners effect
        NSColor.white.setFill()
        NSColor.white.setStroke()
        trianglePath.lineWidth = 6
        trianglePath.stroke()
        trianglePath.fill()

        image.unlockFocus()
        return image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove existing tracking areas
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }

        // Add new tracking area
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    func shouldShowPlayButtonForType() -> Bool {
        // Check if cell is currently playing
        if let wallpaperId = wallpaperId,
           let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           appDelegate.currentlyPlayingCellId == wallpaperId {
            return false  // Don't show play button if already playing
        }

        // Get file extension from ID file
        guard let wallpaperId = wallpaperId,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let assetURL = appDelegate.findAssetURLByWallpaperId(wallpaperId) else {
            return true  // If not downloaded yet, show play button
        }

        let ext = assetURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "heic"]

        // Hide play button for regular images, show for everything else
        return !imageExtensions.contains(ext)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true

        // Add click gesture to entire view if not already added
        if clickGesture == nil {
            let gesture = NSClickGestureRecognizer(target: self, action: #selector(cellClicked(_:)))
            addGestureRecognizer(gesture)
            clickGesture = gesture
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            let w = 12;
            transform = transform.translatedBy(x: CGFloat(-w/2), y: CGFloat(-w/3)) // Adjust these values
            self.layer?.setAffineTransform(transform)
            self.layer?.shadowColor = NSColor.black.cgColor
            self.layer?.shadowOpacity = 0.3
            self.layer?.shadowOffset = CGSize(width: 0, height: 5)
            self.layer?.shadowRadius = 10
            self.layer?.zPosition = 100
        })
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        animateOut()
    }

    func animateOut() {
        guard isMouseInside == false else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.17 // 3 times faster than 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: 0, y: 0) // Adjust these values
            self.layer?.setAffineTransform(transform)
            self.layer?.shadowOpacity = 0
            self.layer?.zPosition = 0

            // Fade out play button
            self.playButtonView?.animator().alphaValue = 0
        })
    }

    func resetImmediately() {
        // No animation - immediate reset
        self.layer?.setAffineTransform(CGAffineTransform.identity)
        self.layer?.shadowOpacity = 0
        self.layer?.zPosition = 0
        self.playButtonView?.alphaValue = 0
    }

    @objc func cellClicked(_ sender: NSClickGestureRecognizer) {
        // self is the HoverScaleView since it's the target
        guard let wallpaperId = self.wallpaperId,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            print("Could not get wallpaper ID or app delegate")
            return
        }

        print("Cell clicked for wallpaper ID: \(wallpaperId)")

        // Download and then play the content in this cell
        appDelegate.downloadAndPlayInCell(wallpaperId: wallpaperId, cellView: self)

        // Also trigger preview panel update
        appDelegate.thumbnailSelected(wallpaperId: wallpaperId)
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
    var favoritesView: NSView?
    var segmentedControl: NSSegmentedControl?
    var currentMenuIndex: Int = 0 // Track selected menu (0=Favorites, 1=Browse)

    // Browser view data
    var wallpaperData: [[String: Any]] = []
    var filteredWallpaperData: [[String: Any]] = []
    var searchField: NSSearchField?
    var typeButton: NSButton?
    var typePopover: NSPopover?
    var selectedTypes: Set<String> = []
    var tagsButton: NSButton?
    var tagsPopover: NSPopover?
    var selectedTags: Set<String> = []
    var sortButton: NSButton?
    var sortPopover: NSPopover?
    var selectedSort: String = ""
    var currentPage: Int = 1
    var isLoadingWallpapers: Bool = false
    var browserScrollView: NSScrollView?
    var browserGridContainer: NSView?
    var guestId: String?
    var useMacOSEndpoint: Bool = true
    var currentlyPlayingCellId: Int? // Track which cell is currently playing

    // Store playback resources for browser cells to prevent deallocation
    var cellRenderers: [Int: ShaderRenderer] = [:]  // wallpaperId -> renderer
    var cellRiveViewModels: [Int: RiveViewModel] = [:]  // wallpaperId -> viewModel

    var homeAssets: [URL] = []
    var currentAssetIndex: Int = 0
    var mediaContainerView: NSView?
    var dotsContainer: NSView?
    var prevButton: NSButton?
    var nextButton: NSButton?
    var currentPlayer: AVPlayer?
    var currentRenderer: ShaderRenderer?
    var currentRiveViewModel: RiveViewModel?
    var setWallpaperButton: NSButton?
    var notificationLabel: NSView?
    var videoWallpaperWindows: [VideoWallpaperWindow] = []
    var shaderWallpaperWindows: [ShaderWallpaperWindow] = []
    var animationWallpaperWindows: [AnimationWallpaperWindow] = []
    var gifWallpaperWindows: [GIFWallpaperWindow] = []

    var screensaverIsPlaying: Bool = true
    var playPauseMenuItem: NSMenuItem?

    // Preview panel elements
    var previewPanelView: NSView?
    var previewContainer: NSView?
    var previewTitleLabel: NSTextField?
    var previewDescriptionLabel: NSTextField?
    var previewFavoriteButton: NSButton?
    var previewPlayer: AVPlayer?
    var previewRenderer: ShaderRenderer?
    var previewRiveViewModel: RiveViewModel?
    var selectedWallpaperId: Int?

    enum WallpaperType {
        case none
        case image
        case video
        case shader
        case animation
        case gif
    }
    var currentWallpaperType: WallpaperType = .none

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force dark mode for the app
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Disable audio for the entire app
        disableAppAudio()

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

    func showNotification(message: String) {
        // Only show notification on home screen, not browser screen
        guard segmentedControl?.selectedSegment == 0 else { return }

        guard let labelView = notificationLabel,
              let textLayer = labelView.layer?.sublayers?.first as? CATextLayer else { return }

        // Update text
        textLayer.string = message

        // Fade in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            labelView.animator().alphaValue = 1.0
        })

        // Fade out after 2.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak labelView] in
            guard let label = labelView else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                label.animator().alphaValue = 0
            })
        }
    }

    func disableAppAudio() {
        // Monitor and mute all Rive animations every 50ms
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.currentRiveViewModel?.riveModel?.volume = 0.0
            for window in self?.animationWallpaperWindows ?? [] {
                window.riveViewModel?.riveModel?.volume = 0.0
            }
        }
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
        let subfolders = ["Videos", "Images", "Shaders", "Animations", "FirstFrames", "IDs", "Favorites"]
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
                    currentWallpaperType = .video
                    screensaverIsPlaying = true
                    updatePlayPauseMenu()
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
                    currentWallpaperType = .shader
                    screensaverIsPlaying = true
                    updatePlayPauseMenu()
                    return
                }
            }
        }

        // Search for animation with same name in Animations folder
        let animationsFolder = assetsFolderURL.appendingPathComponent("Animations")
        let animationExtensions = ["riv"]

        if let files = try? FileManager.default.contentsOfDirectory(at: animationsFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let fileNameWithoutExt = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension.lowercased()

                if fileNameWithoutExt == filename && animationExtensions.contains(ext) {
                    print("Found matching animation: \(file.path)")
                    // Restore animation wallpaper
                    createAnimationWallpapers(animationURL: file)
                    currentWallpaperType = .animation
                    screensaverIsPlaying = true
                    updatePlayPauseMenu()
                    return
                }
            }
        }

        // Search for GIF with same name in Images folder
        let imagesFolder = assetsFolderURL.appendingPathComponent("Images")
        let gifExtensions = ["gif"]

        if let files = try? FileManager.default.contentsOfDirectory(at: imagesFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let fileNameWithoutExt = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension.lowercased()

                if fileNameWithoutExt == filename && gifExtensions.contains(ext) {
                    print("Found matching GIF: \(file.path)")
                    // Restore GIF wallpaper
                    createGIFWallpapers(gifURL: file)
                    currentWallpaperType = .gif
                    screensaverIsPlaying = true
                    updatePlayPauseMenu()
                    return
                }
            }
        }

        print("No matching video, shader, animation, or GIF found for: \(filename)")
    }

    func loadRandomAssets() {
        guard let assetsFolderURL = assetsFolderURL else { return }

        let fileManager = FileManager.default
        var allAssets: [URL] = []

        let subfolders = ["Videos", "Images", "Shaders", "Animations"]
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"]
        let shaderExtensions = ["msl"]
        let animationExtensions = ["riv"]

        for subfolder in subfolders {
            let folderURL = assetsFolderURL.appendingPathComponent(subfolder)

            guard let files = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files {
                let ext = file.pathExtension.lowercased()
                if videoExtensions.contains(ext) || imageExtensions.contains(ext) || shaderExtensions.contains(ext) || animationExtensions.contains(ext) {
                    allAssets.append(file)
                }
            }
        }

        // Shuffle and take up to maxHomeScreenAssets
        homeAssets = Array(allAssets.shuffled().prefix(maxHomeScreenAssets))
        currentAssetIndex = 0

        print("Loaded \(homeAssets.count) random assets")

        // If no assets, switch to browse screen
        if homeAssets.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.segmentedControl?.selectedSegment = 1
                self?.showView(self?.browserView)
            }
        }
    }

    func createMainWindow() {
        // Get main screen dimensions
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Calculate 100% of screen width and height
        let windowWidth = screenFrame.width * 1.0
        let windowHeight = screenFrame.height * 1.0

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

    func createSidebarView(frame: NSRect) -> NSView {
        let sidebar = NSView(frame: frame)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(red: 30/255.0, green: 30/255.0, blue: 30/255.0, alpha: 1.0).cgColor
        sidebar.autoresizingMask = [.height]

        // App icon at top
        let iconSize: CGFloat = 60
        let iconView = NSImageView(frame: NSRect(
            x: (frame.width - iconSize) / 2,
            y: frame.height - iconSize - 30,
            width: iconSize,
            height: iconSize
        ))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        sidebar.addSubview(iconView)

        // App title below icon
        let titleLabel = NSTextField(labelWithString: "WallpicsMac")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(
            x: 20,
            y: frame.height - iconSize - 65,
            width: frame.width - 40,
            height: 25
        )
        titleLabel.autoresizingMask = [.width, .minYMargin]
        sidebar.addSubview(titleLabel)

        // Menu items
        let menuItemHeight: CGFloat = 50
        let menuStartY = frame.height - iconSize - 120
        let menuItems = [
            ("Favorites", "star"),
            ("Browse", "square.grid.2x2")
        ]

        for (index, item) in menuItems.enumerated() {
            let itemY = menuStartY - (CGFloat(index) * menuItemHeight)
            let menuItem = createMenuItem(
                title: item.0,
                icon: item.1,
                frame: NSRect(x: 0, y: itemY, width: frame.width, height: menuItemHeight),
                index: index
            )
            sidebar.addSubview(menuItem)
        }

        return sidebar
    }

    func createMenuItem(title: String, icon: String, frame: NSRect, index: Int) -> NSView {
        let item = NSView(frame: frame)
        item.wantsLayer = true

        // Highlight the currently selected menu item
        if index == currentMenuIndex {
            item.layer?.backgroundColor = NSColor(red: 60/255.0, green: 100/255.0, blue: 150/255.0, alpha: 1.0).cgColor
        }

        // Icon
        let iconView = NSImageView(frame: NSRect(x: 20, y: (frame.height - 24) / 2, width: 24, height: 24))
        if let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            iconView.image = iconImage
            iconView.contentTintColor = .white
        }
        item.addSubview(iconView)

        // Title
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.isBordered = false
        label.isEditable = false
        label.backgroundColor = .clear
        label.frame = NSRect(x: 55, y: (frame.height - 20) / 2, width: frame.width - 70, height: 20)
        item.addSubview(label)

        // Add click gesture
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(menuItemClicked(_:)))
        item.addGestureRecognizer(clickGesture)
        item.identifier = NSUserInterfaceItemIdentifier("menu_item_\(index)")

        return item
    }

    @objc func browseLinkClicked() {
        // Switch to Browse menu
        switchToMenu(index: 1)
    }

    func switchToMenu(index: Int) {
        currentMenuIndex = index

        // Update sidebar highlighting
        if let sidebar = window?.contentView?.subviews.first {
            for subview in sidebar.subviews {
                if let identifier = subview.identifier?.rawValue,
                   identifier.hasPrefix("menu_item_") {
                    subview.layer?.backgroundColor = NSColor.clear.cgColor

                    // Highlight the selected menu item
                    if let indexString = identifier.components(separatedBy: "_").last,
                       let menuIndex = Int(indexString),
                       menuIndex == index {
                        subview.layer?.backgroundColor = NSColor(red: 60/255.0, green: 100/255.0, blue: 150/255.0, alpha: 1.0).cgColor
                    }
                }
            }
        }

        // Switch view
        switch index {
        case 0: // Favorites
            showCenterView(favoritesView)
        case 1: // Browse
            showCenterView(browserView)
        default:
            break
        }
    }

    @objc func menuItemClicked(_ sender: NSClickGestureRecognizer) {
        guard let clickedView = sender.view,
              let identifier = clickedView.identifier?.rawValue,
              let indexString = identifier.components(separatedBy: "_").last,
              let menuIndex = Int(indexString) else { return }

        // Don't do anything if clicking the same menu item
        if menuIndex == currentMenuIndex {
            return
        }

        // Refresh favorites view if switching to it
        if menuIndex == 0 {
            let isEmpty = isFavoritesFolderEmpty()
            if isEmpty {
                createFavoritesView(frame: favoritesView?.frame ?? .zero)
            }
        }

        switchToMenu(index: menuIndex)
    }

    func createFavoritesView(frame: NSRect) {
        favoritesView = NSView(frame: frame)
        favoritesView?.wantsLayer = true
        favoritesView?.autoresizingMask = [.width, .height]

        guard let favoritesView = favoritesView else { return }

        // Check if favorites is empty
        if isFavoritesFolderEmpty() {
            // Clickable link for entire message
            let linkButton = NSButton(frame: NSRect(
                x: (frame.width - 500) / 2,
                y: (frame.height - 80) / 2,
                width: 500,
                height: 80
            ))
            linkButton.title = "Favorites folder is empty,\nbrowse templates and add something"
            linkButton.isBordered = false
            linkButton.setButtonType(.momentaryChange)
            linkButton.bezelStyle = .inline
            linkButton.contentTintColor = .systemBlue
            linkButton.font = NSFont.systemFont(ofSize: 18, weight: .medium)
            linkButton.alignment = .center
            linkButton.lineBreakMode = .byWordWrapping
            linkButton.target = self
            linkButton.action = #selector(browseLinkClicked)
            linkButton.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

            favoritesView.addSubview(linkButton)
        } else {
            // TODO: Show favorites grid
            let label = NSTextField(labelWithString: "Favorites content will be here")
            label.font = NSFont.systemFont(ofSize: 18)
            label.textColor = .labelColor
            label.alignment = .center
            label.frame = NSRect(x: 0, y: frame.height / 2, width: frame.width, height: 30)
            label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            favoritesView.addSubview(label)
        }
    }

    func createPreviewView(frame: NSRect) -> NSView {
        let preview = NSView(frame: frame)
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(red: 25/255.0, green: 25/255.0, blue: 25/255.0, alpha: 1.0).cgColor
        preview.autoresizingMask = [.height, .minXMargin]
        previewPanelView = preview

        // Preview container at top (will show selected wallpaper preview)
        let previewHeight: CGFloat = frame.width * 0.75 // 4:3 aspect ratio
        let container = NSView(frame: NSRect(
            x: 20,
            y: frame.height - previewHeight - 20,
            width: frame.width - 40,
            height: previewHeight
        ))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.darkGray.cgColor
        container.layer?.cornerRadius = 8
        container.autoresizingMask = [.width, .minYMargin]
        preview.addSubview(container)
        previewContainer = container

        // Placeholder text
        let placeholderLabel = NSTextField(labelWithString: "Select a wallpaper")
        placeholderLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.frame = NSRect(
            x: 0,
            y: (previewHeight - 25) / 2,
            width: container.bounds.width,
            height: 25
        )
        placeholderLabel.identifier = NSUserInterfaceItemIdentifier("placeholder")
        placeholderLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        container.addSubview(placeholderLabel)

        // Title below preview
        let titleY = frame.height - previewHeight - 80
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: titleY, width: frame.width - 40, height: 30)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        preview.addSubview(titleLabel)
        previewTitleLabel = titleLabel

        // Buttons container (Set, Delete, Favorite)
        let buttonsY = titleY - 70
        let setButtonWidth: CGFloat = 240
        let setButtonHeight: CGFloat = 37.5
        let circularButtonSize: CGFloat = 37.5
        let buttonSpacing: CGFloat = 15

        // Set button with icon
        let setButton = NSButton(frame: NSRect(x: 20, y: buttonsY, width: setButtonWidth, height: setButtonHeight))
        setButton.title = ""
        setButton.isBordered = false
        setButton.target = self
        setButton.action = #selector(previewSetButtonClicked)
        setButton.autoresizingMask = [.maxXMargin, .minYMargin]
        setButton.wantsLayer = true
        setButton.layer?.backgroundColor = NSColor(calibratedRed: 0.6, green: 0.75, blue: 0.9, alpha: 1.0).cgColor
        setButton.layer?.cornerRadius = setButtonHeight / 2

        // Create Set button content with icon and text
        if let pictureIcon = NSImage(systemSymbolName: "photo", accessibilityDescription: "Set Wallpaper") {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            let text = "Set" as NSString
            let textSize = text.size(withAttributes: attrs)
            let iconSize: CGFloat = 20
            let spacing: CGFloat = 8
            let totalWidth = iconSize + spacing + textSize.width

            let combinedImage = NSImage(size: NSSize(width: totalWidth, height: iconSize))
            combinedImage.lockFocus()

            // Draw icon in black
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
            let configuredIcon = pictureIcon.withSymbolConfiguration(config)
            NSColor.black.set()
            configuredIcon?.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))

            // Draw text
            let textY = (iconSize - textSize.height) / 2
            let textX = iconSize + spacing
            text.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            combinedImage.unlockFocus()
            setButton.image = combinedImage
            setButton.imagePosition = .imageOnly
        }

        preview.addSubview(setButton)

        // Delete button (circular with coral background)
        let deleteButton = NSButton(frame: NSRect(
            x: 20 + setButtonWidth + buttonSpacing,
            y: buttonsY,
            width: circularButtonSize,
            height: circularButtonSize
        ))
        deleteButton.title = ""
        deleteButton.isBordered = false
        deleteButton.target = self
        deleteButton.action = #selector(previewDeleteButtonClicked)
        deleteButton.autoresizingMask = [.maxXMargin, .minYMargin]
        deleteButton.wantsLayer = true
        deleteButton.layer?.backgroundColor = NSColor(calibratedRed: 0.9, green: 0.5, blue: 0.45, alpha: 1.0).cgColor
        deleteButton.layer?.cornerRadius = circularButtonSize / 2

        if let trashIcon = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete") {
            trashIcon.isTemplate = true
            let iconImage = NSImage(size: NSSize(width: 24, height: 24))
            iconImage.lockFocus()
            trashIcon.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
            iconImage.unlockFocus()
            deleteButton.image = iconImage
            deleteButton.imagePosition = .imageOnly
            deleteButton.contentTintColor = .white
        }

        preview.addSubview(deleteButton)

        // Favorite button (circular with gray background)
        let favoriteButton = NSButton(frame: NSRect(
            x: 20 + setButtonWidth + buttonSpacing + circularButtonSize + buttonSpacing,
            y: buttonsY,
            width: circularButtonSize,
            height: circularButtonSize
        ))
        favoriteButton.title = ""
        favoriteButton.isBordered = false
        favoriteButton.target = self
        favoriteButton.action = #selector(previewFavoriteButtonClicked)
        favoriteButton.autoresizingMask = [.maxXMargin, .minYMargin]
        favoriteButton.wantsLayer = true
        favoriteButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 1.0).cgColor
        favoriteButton.layer?.cornerRadius = circularButtonSize / 2

        if let starIcon = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite") {
            starIcon.isTemplate = true
            let iconImage = NSImage(size: NSSize(width: 24, height: 24))
            iconImage.lockFocus()
            starIcon.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
            iconImage.unlockFocus()
            favoriteButton.image = iconImage
            favoriteButton.imagePosition = .imageOnly
            favoriteButton.contentTintColor = .white
        }

        preview.addSubview(favoriteButton)
        previewFavoriteButton = favoriteButton

        // Description text below buttons
        let descriptionY: CGFloat = 20
        let descriptionHeight: CGFloat = buttonsY - 40
        let descriptionLabel = NSTextField(labelWithString: "")
        descriptionLabel.font = NSFont.systemFont(ofSize: 16)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .left
        descriptionLabel.frame = NSRect(x: 20, y: descriptionY, width: frame.width - 40, height: descriptionHeight)
        descriptionLabel.autoresizingMask = [.width, .minYMargin, .height]
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.lineBreakMode = .byWordWrapping
        preview.addSubview(descriptionLabel)
        previewDescriptionLabel = descriptionLabel

        return preview
    }

    @objc func previewSetButtonClicked() {
        print("Preview Set button clicked")
        // TODO: Implement set wallpaper from preview
    }

    @objc func previewDeleteButtonClicked() {
        print("Preview Delete button clicked")
        // TODO: Implement delete wallpaper
    }

    @objc func previewFavoriteButtonClicked() {
        print("Preview Favorite button clicked")

        guard let wallpaperId = selectedWallpaperId,
              let assetsFolderURL = assetsFolderURL else {
            print("No wallpaper selected or assets folder not available")
            return
        }

        // Remove from Favorites folder
        let favoritesFolder = assetsFolderURL.appendingPathComponent("Favorites")
        let favoriteFile = favoritesFolder.appendingPathComponent("\(wallpaperId)")

        do {
            if FileManager.default.fileExists(atPath: favoriteFile.path) {
                try FileManager.default.removeItem(at: favoriteFile)
                print("Removed wallpaper \(wallpaperId) from favorites")

                // Update button color to gray (not in favorites)
                previewFavoriteButton?.layer?.backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 1.0).cgColor
            } else {
                print("Wallpaper \(wallpaperId) not in favorites")
            }
        } catch {
            print("Error removing from favorites: \(error)")
        }
    }

    func thumbnailSelected(wallpaperId: Int) {
        print("Thumbnail selected: \(wallpaperId)")

        // Find the wallpaper data
        guard let wallpaper = wallpaperData.first(where: { $0["id"] as? Int == wallpaperId }) else {
            print("Wallpaper not found in data")
            return
        }

        // Update preview panel with wallpaper info
        updatePreviewPanel(with: wallpaper)

        // Start playback in preview panel after download completes
        // This will be triggered from downloadAndPlayInCell callback
    }

    func updatePreviewPanel(with wallpaper: [String: Any]) {
        guard let previewContainer = previewContainer else { return }

        let wallpaperId = wallpaper["id"] as? Int ?? 0
        selectedWallpaperId = wallpaperId

        // Update title
        let name = wallpaper["name"] as? String ?? "Unknown"
        let description = wallpaper["description"] as? String ?? ""

        previewTitleLabel?.stringValue = name
        previewDescriptionLabel?.stringValue = description

        // Update favorite button color based on whether it's in favorites
        if let assetsFolderURL = assetsFolderURL {
            let favoritesFolder = assetsFolderURL.appendingPathComponent("Favorites")
            let favoriteFile = favoritesFolder.appendingPathComponent("\(wallpaperId)")
            let isInFavorites = FileManager.default.fileExists(atPath: favoriteFile.path)

            previewFavoriteButton?.layer?.backgroundColor = isInFavorites
                ? NSColor.systemYellow.cgColor
                : NSColor(calibratedWhite: 0.35, alpha: 1.0).cgColor
        }

        // Remove placeholder if it exists
        previewContainer.subviews.first(where: { $0.identifier?.rawValue == "placeholder" })?.removeFromSuperview()

        // Clean up previous preview content
        cleanupPreviewPlayback()

        // Find the asset URL
        guard let assetURL = findAssetURLByWallpaperId(wallpaperId) else {
            print("Asset not downloaded yet for preview")
            return
        }

        // Start playback based on file type
        let ext = assetURL.pathExtension.lowercased()

        if ["mp4", "mov", "m4v"].contains(ext) {
            // Video playback
            playVideoInPreview(url: assetURL)
        } else if ext == "msl" {
            // Shader playback
            playShaderInPreview(url: assetURL)
        } else if ext == "riv" {
            // Rive animation playback
            playRiveInPreview(url: assetURL)
        } else if ext == "gif" {
            // GIF playback
            playGIFInPreview(url: assetURL)
        } else {
            // Static image
            showImageInPreview(url: assetURL)
        }
    }

    func cleanupPreviewPlayback() {
        // Stop and remove any existing preview playback
        previewPlayer?.pause()
        previewPlayer = nil
        previewRenderer = nil
        previewRiveViewModel = nil

        // Remove all subviews from preview container except placeholder
        previewContainer?.subviews.forEach { subview in
            if subview.identifier?.rawValue != "placeholder" {
                subview.removeFromSuperview()
            }
        }
    }

    func playVideoInPreview(url: URL) {
        guard let previewContainer = previewContainer else { return }

        let player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = previewContainer.bounds
        playerLayer.videoGravity = .resizeAspectFill

        let containerView = NSView(frame: previewContainer.bounds)
        containerView.wantsLayer = true
        containerView.layer?.addSublayer(playerLayer)
        containerView.autoresizingMask = [.width, .height]

        previewContainer.addSubview(containerView)

        player.play()
        previewPlayer = player

        // Loop video
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    func playShaderInPreview(url: URL) {
        guard let previewContainer = previewContainer else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        guard let shaderSource = try? String(contentsOf: url, encoding: .utf8) else { return }

        let metalView = MTKView(frame: previewContainer.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]

        let renderer = ShaderRenderer(device: device, shaderSource: shaderSource)
        metalView.delegate = renderer

        previewContainer.addSubview(metalView)
        previewRenderer = renderer
    }

    func playRiveInPreview(url: URL) {
        guard let previewContainer = previewContainer else { return }

        let viewModel = RiveViewModel(
            webURL: url.absoluteString,
            fit: .fill,
            alignment: .center,
            loadCdn: false
        )

        let riveView = viewModel.createRiveView()
        riveView.frame = previewContainer.bounds
        riveView.autoresizingMask = [.width, .height]
        previewContainer.addSubview(riveView)
        previewRiveViewModel = viewModel
    }

    func playGIFInPreview(url: URL) {
        guard let previewContainer = previewContainer else { return }

        guard let image = NSImage(contentsOf: url) else { return }

        // Calculate scale to fill container while maintaining aspect ratio
        let containerSize = previewContainer.bounds.size
        let imageSize = image.size

        let scaleWidth = containerSize.width / imageSize.width
        let scaleHeight = containerSize.height / imageSize.height
        let scale = max(scaleWidth, scaleHeight) // Use max to ensure both dimensions are covered

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Center the scaled image
        let x = (containerSize.width - scaledWidth) / 2
        let y = (containerSize.height - scaledHeight) / 2

        let imageView = NSImageView(frame: NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
        imageView.image = image
        imageView.animates = true
        imageView.canDrawSubviewsIntoLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        previewContainer.addSubview(imageView)
    }

    func showImageInPreview(url: URL) {
        guard let previewContainer = previewContainer else { return }

        let imageView = NSImageView(frame: previewContainer.bounds)
        imageView.imageScaling = .scaleNone

        if let image = NSImage(contentsOf: url) {
            // Calculate scale to fill container while maintaining aspect ratio
            let containerSize = previewContainer.bounds.size
            let imageSize = image.size

            let scaleWidth = containerSize.width / imageSize.width
            let scaleHeight = containerSize.height / imageSize.height
            let scale = max(scaleWidth, scaleHeight) // Use max to ensure both dimensions are covered

            let scaledWidth = imageSize.width * scale
            let scaledHeight = imageSize.height * scale

            // Center the scaled image
            let x = (containerSize.width - scaledWidth) / 2
            let y = (containerSize.height - scaledHeight) / 2

            let scaledImageView = NSImageView(frame: NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
            scaledImageView.image = image
            scaledImageView.imageScaling = .scaleProportionallyUpOrDown
            previewContainer.addSubview(scaledImageView)
            return
        }

        imageView.autoresizingMask = [.width, .height]
        previewContainer.addSubview(imageView)
    }

    func setupWindowContent(frame: NSRect) {
        guard let window = window else { return }

        // Main container view
        let mainView = NSView(frame: frame)
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = mainView

        // Three-column layout
        let sidebarWidth: CGFloat = 250
        let previewWidth: CGFloat = 400
        let centerWidth = frame.width - sidebarWidth - previewWidth

        // Check if Favorites folder is empty
        let favoritesEmpty = isFavoritesFolderEmpty()

        // Set initial menu index (0=Favorites, 1=Browse)
        currentMenuIndex = favoritesEmpty ? 1 : 0

        // LEFT SIDEBAR
        let sidebarView = createSidebarView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: frame.height))
        mainView.addSubview(sidebarView)

        // CENTER COLUMN (container for favorites/browser views)
        let centerFrame = NSRect(x: sidebarWidth, y: 0, width: centerWidth, height: frame.height)
        contentContainer = NSView(frame: centerFrame)
        contentContainer?.wantsLayer = true
        contentContainer?.autoresizingMask = [.width, .height]
        if let contentContainer = contentContainer {
            mainView.addSubview(contentContainer)
        }

        // Create Favorites and Browser views
        createFavoritesView(frame: NSRect(x: 0, y: 0, width: centerWidth, height: frame.height))
        createBrowserView(frame: NSRect(x: 0, y: 0, width: centerWidth, height: frame.height))

        // Show appropriate view based on favorites content
        if favoritesEmpty {
            showCenterView(browserView)
        } else {
            showCenterView(favoritesView)
        }

        // RIGHT PREVIEW PANEL
        let previewFrame = NSRect(x: sidebarWidth + centerWidth, y: 0, width: previewWidth, height: frame.height)
        let previewView = createPreviewView(frame: previewFrame)
        mainView.addSubview(previewView)

        // Initialize guest ID and fetch wallpapers for Browse
        initializeGuestId { [weak self] in
            self?.fetchWallpapers(page: 1)
        }
    }

    func isFavoritesFolderEmpty() -> Bool {
        guard let assetsFolderURL = assetsFolderURL else { return true }
        let favoritesFolder = assetsFolderURL.appendingPathComponent("Favorites")

        guard let files = try? FileManager.default.contentsOfDirectory(at: favoritesFolder, includingPropertiesForKeys: nil) else {
            return true
        }

        // Filter out hidden files
        let visibleFiles = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        return visibleFiles.isEmpty
    }

    func showCenterView(_ view: NSView?) {
        contentContainer?.subviews.forEach { $0.removeFromSuperview() }
        if let view = view {
            contentContainer?.addSubview(view)
        }
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
        setAsWallpaperWithPath(assetURL: assetURL)
    }

    func setAsWallpaperWithPath(assetURL: URL) {
        let ext = assetURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "bmp", "tiff", "heic"]
        let gifExtensions = ["gif"]
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let shaderExtensions = ["msl"]
        let animationExtensions = ["riv"]

        var wallpaperURL: URL? = assetURL
        let isVideo = videoExtensions.contains(ext)
        let isShader = shaderExtensions.contains(ext)
        let isAnimation = animationExtensions.contains(ext)
        let isGIF = gifExtensions.contains(ext)

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
        } else if isAnimation {
            // For animations, try to get existing first frame (no placeholder)
            if let firstFrameURL = renderFirstFrameAnimation(from: assetURL) {
                wallpaperURL = firstFrameURL
            } else {
                // No first frame yet, skip static wallpaper setting
                wallpaperURL = nil
            }
        } else if isGIF {
            // For GIFs, render first frame
            if let firstFrameURL = renderFirstFrameGIF(from: assetURL) {
                wallpaperURL = firstFrameURL
            } else {
                wallpaperURL = nil
            }
        } else if !imageExtensions.contains(ext) {
            // Not an image, video, shader, animation, or GIF
            return
        }

        // Set static wallpaper (first frame for videos/shaders/animations, actual image for images)
        do {
            let workspace = NSWorkspace.shared
            if let screen = NSScreen.main {
                // Set static wallpaper only if wallpaperURL exists
                if let wallpaperURL = wallpaperURL {
                    try workspace.setDesktopImageURL(wallpaperURL, for: screen, options: [:])
                    print("Wallpaper set successfully")
                    showNotification(message: "Wallpaper set successfully")

                    // Save wallpaper path to settings.txt
                    saveWallpaperPath(wallpaperURL)
                }

                // Create animated wallpaper windows based on type
                if isVideo {
                    createVideoWallpapers(videoURL: assetURL)
                    stopShaderWallpapers()
                    stopAnimationWallpapers()
                    stopGIFWallpapers()
                    currentWallpaperType = .video
                } else if isShader {
                    createShaderWallpapers(shaderURL: assetURL)
                    stopVideoWallpapers()
                    stopAnimationWallpapers()
                    stopGIFWallpapers()
                    currentWallpaperType = .shader
                } else if isAnimation {
                    createAnimationWallpapers(animationURL: assetURL)
                    stopVideoWallpapers()
                    stopShaderWallpapers()
                    stopGIFWallpapers()
                    currentWallpaperType = .animation
                } else if isGIF {
                    createGIFWallpapers(gifURL: assetURL)
                    stopVideoWallpapers()
                    stopShaderWallpapers()
                    stopAnimationWallpapers()
                    currentWallpaperType = .gif
                } else {
                    // Stop any existing wallpapers when setting a static image
                    stopVideoWallpapers()
                    stopShaderWallpapers()
                    stopAnimationWallpapers()
                    stopGIFWallpapers()
                    currentWallpaperType = .image
                }

                // Reset to playing state when new wallpaper is set
                screensaverIsPlaying = true
                updatePlayPauseMenu()
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

    func stopAnimationWallpapers() {
        for window in animationWallpaperWindows {
            window.stop()
            window.close()
        }
        animationWallpaperWindows.removeAll()
        print("Stopped all animation wallpapers")
    }

    func createAnimationWallpapers(animationURL: URL) {
        // Stop any existing animation wallpapers first
        stopAnimationWallpapers()

        // Create animation wallpaper window for each screen
        for screen in NSScreen.screens {
            let wallpaperWindow = AnimationWallpaperWindow(screen: screen, animationURL: animationURL)
            wallpaperWindow.orderBack(nil)
            animationWallpaperWindows.append(wallpaperWindow)
        }

        print("Created animation wallpaper windows for \(NSScreen.screens.count) screen(s)")

        // After 0.3 seconds, capture the frame from the wallpaper window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let assetsFolderURL = self.assetsFolderURL,
                  let firstWallpaperWindow = self.animationWallpaperWindows.first,
                  let riveView = firstWallpaperWindow.contentView else {
                print("No window or view for capture")
                return
            }

            // Get window number
            let windowID = CGWindowID(firstWallpaperWindow.windowNumber)

            // Capture the window image
            let imageRef = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )

            guard let cgImage = imageRef else {
                print("Window capture failed")
                return
            }

            // Get scale and crop to RiveView frame
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0

            let viewFrameInWindow = riveView.convert(riveView.bounds, to: nil)

            let cropRect = CGRect(
                x: viewFrameInWindow.origin.x * scale,
                y: (firstWallpaperWindow.frame.height - viewFrameInWindow.maxY) * scale,
                width: viewFrameInWindow.width * scale,
                height: viewFrameInWindow.height * scale
            )

            guard let cropped = cgImage.cropping(to: cropRect) else {
                print("Crop failed")
                return
            }

            let image = NSImage(cgImage: cropped, size: riveView.bounds.size)

            // Convert to JPEG
            guard let tiffData = image.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                print("Failed to convert captured image to JPEG")
                return
            }

            let firstFramesFolder = assetsFolderURL.appendingPathComponent("FirstFrames")
            let animationName = animationURL.deletingPathExtension().lastPathComponent
            let imageURL = firstFramesFolder.appendingPathComponent("\(animationName).jpg")

            do {
                // Delete old file first to avoid macOS caching
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    try? FileManager.default.removeItem(at: imageURL)
                    print("Deleted old thumbnail")
                }

                // Save new captured frame
                try jpegData.write(to: imageURL)
                print("Captured and saved animation thumbnail using window capture: \(imageURL.path)")
            } catch {
                print("Failed to save captured frame: \(error)")
            }
        }
    }

    func stopGIFWallpapers() {
        for window in gifWallpaperWindows {
            window.stop()
            window.close()
        }
        gifWallpaperWindows.removeAll()
        print("Stopped all GIF wallpapers")
    }

    func createGIFWallpapers(gifURL: URL) {
        // Stop any existing GIF wallpapers first
        stopGIFWallpapers()

        // Create GIF wallpaper window for each screen
        for screen in NSScreen.screens {
            let wallpaperWindow = GIFWallpaperWindow(screen: screen, gifURL: gifURL)
            wallpaperWindow.orderBack(nil)
            gifWallpaperWindows.append(wallpaperWindow)
        }

        print("Created GIF wallpaper windows for \(NSScreen.screens.count) screen(s)")
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

    func renderFirstFrameGIF(from gifURL: URL) -> URL? {
        guard let assetsFolderURL = assetsFolderURL else { return nil }

        let firstFramesFolder = assetsFolderURL.appendingPathComponent("FirstFrames")
        let gifName = gifURL.deletingPathExtension().lastPathComponent
        let imageURL = firstFramesFolder.appendingPathComponent("\(gifName).jpg")

        // Check if already rendered
        if FileManager.default.fileExists(atPath: imageURL.path) {
            print("First frame already exists: \(imageURL.path)")
            return imageURL
        }

        // Extract first frame from GIF using CGImageSource
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("Failed to load GIF")
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // Convert to JPEG and save
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            print("Failed to convert to JPEG")
            return nil
        }

        do {
            try jpegData.write(to: imageURL)
            print("GIF first frame saved to: \(imageURL.path)")
            return imageURL
        } catch {
            print("Failed to save GIF first frame: \(error)")
            return nil
        }
    }

    func renderFirstFrameAnimation(from animationURL: URL) -> URL? {
        guard let assetsFolderURL = assetsFolderURL else { return nil }

        let firstFramesFolder = assetsFolderURL.appendingPathComponent("FirstFrames")
        let animationName = animationURL.deletingPathExtension().lastPathComponent
        let imageURL = firstFramesFolder.appendingPathComponent("\(animationName).jpg")

        // Check if already rendered
        if FileManager.default.fileExists(atPath: imageURL.path) {
            print("First frame already exists: \(imageURL.path)")
            return imageURL
        }

        // Return nil immediately - no placeholder
        return nil
    }

    func loadAssetAtIndex(_ index: Int) {
        guard index >= 0 && index < homeAssets.count else { return }
        guard let mediaContainerView = mediaContainerView else { return }

        // Stop and remove current player
        currentPlayer?.pause()
        currentPlayer = nil
        currentRenderer = nil

        // Stop Rive animation safely
        if let riveVM = currentRiveViewModel {
            riveVM.pause()
            currentRiveViewModel = nil
        }

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

        // Remove existing media views
        mediaContainerView.subviews.forEach { $0.removeFromSuperview() }

        let assetURL = homeAssets[index]
        let ext = assetURL.pathExtension.lowercased()

        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "bmp", "tiff", "heic"]
        let gifExtensions = ["gif"]
        let shaderExtensions = ["msl"]
        let animationExtensions = ["riv"]

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
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }

        } else if gifExtensions.contains(ext) {
            // Load GIF with animation - fill entire view properly
            if let image = NSImage(contentsOf: assetURL) {
                // Calculate aspect fill frame
                let imageSize = image.size
                let viewSize = mediaContainerView.bounds.size
                let imageAspect = imageSize.width / imageSize.height
                let viewAspect = viewSize.width / viewSize.height

                var scaledFrame = mediaContainerView.bounds
                if imageAspect > viewAspect {
                    // Image is wider - fit height and crop width
                    let scaledWidth = viewSize.height * imageAspect
                    scaledFrame = NSRect(
                        x: (viewSize.width - scaledWidth) / 2,
                        y: 0,
                        width: scaledWidth,
                        height: viewSize.height
                    )
                } else {
                    // Image is taller - fit width and crop height
                    let scaledHeight = viewSize.width / imageAspect
                    scaledFrame = NSRect(
                        x: 0,
                        y: (viewSize.height - scaledHeight) / 2,
                        width: viewSize.width,
                        height: scaledHeight
                    )
                }

                let imageView = NSImageView(frame: scaledFrame)
                imageView.imageScaling = .scaleAxesIndependently
                imageView.animates = true
                imageView.image = image

                // Container to clip overflow
                let containerView = NSView(frame: mediaContainerView.bounds)
                containerView.wantsLayer = true
                containerView.layer?.masksToBounds = true
                containerView.autoresizingMask = [.width, .height]
                containerView.addSubview(imageView)

                mediaContainerView.addSubview(containerView)
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
        } else if animationExtensions.contains(ext) {
            // Load animation
            let viewModel = RiveViewModel(
                webURL: assetURL.absoluteString,
                fit: .fill,
                alignment: .center,
                loadCdn: false
            )
            currentRiveViewModel = viewModel

            let riveView = viewModel.createRiveView()
            riveView.frame = mediaContainerView.bounds
            riveView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
            riveView.wantsLayer = true // Essential for layer-based capture

            mediaContainerView.addSubview(riveView)

            // Start playing
            viewModel.play(loop: RiveLoop.loop)

            // Set volume to 0 multiple times with delays
            for i in 0...audioMuteRetryCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak viewModel] in
                    viewModel?.riveModel?.volume = 0.0
                }
            }
        }

        // Enable/disable wallpaper button based on asset type (works for images, videos, shaders, animations, and GIFs)
        setWallpaperButton?.isEnabled = imageExtensions.contains(ext) || gifExtensions.contains(ext) || videoExtensions.contains(ext) || shaderExtensions.contains(ext) || animationExtensions.contains(ext)

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

    func createDropdownButton(iconName: String, title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = ""
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.autoresizingMask = [.minXMargin, .minYMargin]

        if let leftIcon = NSImage(systemSymbolName: iconName, accessibilityDescription: title),
           let chevronImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Dropdown") {
            leftIcon.isTemplate = true
            chevronImage.isTemplate = true

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.controlTextColor
            ]
            let text = title as NSString
            let textSize = text.size(withAttributes: attrs)
            let padding: CGFloat = 12
            let combinedWidth = frame.width
            let combinedHeight = max(leftIcon.size.height, textSize.height, chevronImage.size.height)

            let combinedImage = NSImage(size: NSSize(width: combinedWidth, height: combinedHeight))
            combinedImage.isTemplate = true
            combinedImage.lockFocus()

            // Draw left icon (left-aligned, centered vertically)
            let iconY = (combinedHeight - leftIcon.size.height) / 2
            leftIcon.draw(at: NSPoint(x: padding, y: iconY), from: NSRect.zero, operation: .sourceOver, fraction: 1.0)

            // Draw chevron on right (right-aligned, centered vertically)
            let chevronY = (combinedHeight - chevronImage.size.height) / 2
            chevronImage.draw(at: NSPoint(x: combinedWidth - chevronImage.size.width - padding, y: chevronY), from: NSRect.zero, operation: .sourceOver, fraction: 1.0)

            // Draw text in center (centered horizontally and vertically)
            let textY = (combinedHeight - textSize.height) / 2
            let textX = (combinedWidth - textSize.width) / 2
            text.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            combinedImage.unlockFocus()
            button.image = combinedImage
            button.imagePosition = .imageOnly
        }

        return button
    }

    func createBrowserView(frame: NSRect) {
        browserView = NSView(frame: frame)
        browserView?.wantsLayer = true
        browserView?.autoresizingMask = [.width, .height]

        guard let browserView = browserView else { return }

        // Create controls row at top with padding
        let controlsHeight: CGFloat = 30
        let padding: CGFloat = 20
        let controlsTopOffset: CGFloat = 10
        let controlsY = frame.height - controlsHeight - controlsTopOffset
        let comboboxSpacing: CGFloat = 10

        // Search field (takes remaining width)
        let comboboxWidth: CGFloat = 150
        let searchWidth = frame.width - (padding * 2) - (comboboxWidth * 3) - (comboboxSpacing * 3)
        let search = NSSearchField(frame: NSRect(
            x: padding,
            y: controlsY,
            width: searchWidth,
            height: controlsHeight
        ))
        search.placeholderString = "Search wallpapers..."
        search.autoresizingMask = [.width, .minYMargin]
        search.target = self
        search.action = #selector(searchFieldChanged(_:))
        searchField = search
        browserView.addSubview(search)

        // Type button
        let typeButtonX = padding + searchWidth + comboboxSpacing
        let typeBtn = createDropdownButton(
            iconName: "square.stack.3d.down.right",
            title: "Type",
            frame: NSRect(x: typeButtonX, y: controlsY, width: comboboxWidth, height: controlsHeight),
            action: #selector(typeButtonClicked(_:))
        )
        typeButton = typeBtn
        browserView.addSubview(typeBtn)

        // Tags button
        let tagsButtonX = typeButtonX + comboboxWidth + comboboxSpacing
        let tagsBtn = createDropdownButton(
            iconName: "tag",
            title: "Tags",
            frame: NSRect(x: tagsButtonX, y: controlsY, width: comboboxWidth, height: controlsHeight),
            action: #selector(tagsButtonClicked(_:))
        )
        tagsButton = tagsBtn
        browserView.addSubview(tagsBtn)

        // Sort button
        let sortButtonX = tagsButtonX + comboboxWidth + comboboxSpacing
        let sortBtn = createDropdownButton(
            iconName: "arrow.up.arrow.down",
            title: "Sort",
            frame: NSRect(x: sortButtonX, y: controlsY, width: comboboxWidth, height: controlsHeight),
            action: #selector(sortButtonClicked(_:))
        )
        sortButton = sortBtn
        browserView.addSubview(sortBtn)

        // Create scroll view below controls
        let scrollViewY: CGFloat = 0
        let scrollViewHeight = controlsY - 10
        let scrollView = NSScrollView(frame: NSRect(
            x: 0,
            y: scrollViewY,
            width: frame.width,
            height: scrollViewHeight
        ))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.backgroundColor = .windowBackgroundColor
        browserScrollView = scrollView

        // Create grid container
        let gridContainer = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        gridContainer.wantsLayer = true
        browserGridContainer = gridContainer

        scrollView.documentView = gridContainer
        browserView.addSubview(scrollView)

        // Listen for scroll end to check mouse position on all cells
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        // Show loading message
        let loadingLabel = NSTextField(labelWithString: "Loading wallpapers...")
        loadingLabel.font = NSFont.systemFont(ofSize: 18)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.frame = NSRect(x: 0, y: frame.height / 2 - 15, width: frame.width, height: 30)
        gridContainer.addSubview(loadingLabel)

        // Initialize guest ID and fetch wallpapers
        initializeGuestId { [weak self] in
            self?.fetchWallpapers(page: 1)
        }
    }

    func initializeGuestId(completion: @escaping () -> Void) {
        // Try to load saved guest ID
        if let assetsFolderURL = assetsFolderURL {
            let guestIdURL = assetsFolderURL.appendingPathComponent("guest_id.txt")
            if let savedGuestId = try? String(contentsOf: guestIdURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !savedGuestId.isEmpty {
                self.guestId = savedGuestId
                print("Loaded guest ID: \(savedGuestId)")
                completion()
                return
            }
        }

        // No saved guest ID, request new one
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let token = md5Hash(timestamp + "wall")

        let urlString = "https://backend.wallpics.app/api/init-guest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(timestamp, forHTTPHeaderField: "x-auth")
        request.setValue(token, forHTTPHeaderField: "x-token")
        request.setValue("1", forHTTPHeaderField: "x-get-guest-id")

        print("Requesting new guest ID...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Debug: Print HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                print("Guest ID HTTP Status Code: \(httpResponse.statusCode)")
            }

            if let error = error {
                print("Guest ID request error: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                print("No guest ID data received")
                return
            }

            // Debug: Print raw response
            if let responseString = String(data: data, encoding: .utf8) {
                print("Guest ID Raw Response: \(responseString.prefix(500))")
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataDict = json["data"] as? [String: Any],
                   let guestId = dataDict["guestId"] as? String {
                    self.guestId = guestId
                    print("Received guest ID: \(guestId)")

                    // Save guest ID
                    if let assetsFolderURL = self.assetsFolderURL {
                        let guestIdURL = assetsFolderURL.appendingPathComponent("guest_id.txt")
                        try? guestId.write(to: guestIdURL, atomically: true, encoding: .utf8)
                    }

                    completion()
                } else {
                    print("ERROR: Failed to extract guest ID from response")
                }
            } catch {
                print("Guest ID parse error: \(error)")
            }
        }.resume()
    }

    func md5Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func fetchWallpapers(page: Int) {
        guard !isLoadingWallpapers else { return }
        guard let guestId = guestId else {
            print("No guest ID available")
            return
        }
        isLoadingWallpapers = true

        // Generate auth headers
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let token = md5Hash(timestamp + "wall")

        let endpoint = useMacOSEndpoint ? "wallpapers/macos" : "wallpaper-list"
        let urlString = "https://backend.wallpics.app/api/\(endpoint)?categorySlug=all&timestamp=\(timestamp)&page=\(page)&per_page=24&paginated=1&sortOrder=desc&nsfwContent=0"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(timestamp, forHTTPHeaderField: "x-auth")
        request.setValue(token, forHTTPHeaderField: "x-token")
        request.setValue(guestId, forHTTPHeaderField: "x-guest-id")

        print("Fetching wallpapers - URL: \(urlString)")
        print("Headers: x-auth=\(timestamp), x-token=\(token), x-guest-id=\(guestId)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.isLoadingWallpapers = false
            }

            // Debug: Print HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                print("HTTP Status Code: \(httpResponse.statusCode)")
            }

            if let error = error {
                print("API Error: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                print("No data received")
                return
            }

            // Debug: Print raw response
            if let responseString = String(data: data, encoding: .utf8) {
                print("Raw API Response: \(responseString.prefix(2000))")
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "success",
                   let responseData = json["data"] as? [[String: Any]] {

                    print("Successfully parsed \(responseData.count) wallpapers")

                    DispatchQueue.main.async {
                        if page == 1 {
                            self.wallpaperData = responseData
                            self.displayGlobalTags()
                        } else {
                            self.wallpaperData.append(contentsOf: responseData)
                        }
                        self.currentPage = page
                        self.filterWallpapers()
                    }
                }
            } catch {
                print("JSON Parse Error: \(error)")
            }
        }.resume()
    }

    func displayWallpapers() {
        guard let gridContainer = browserGridContainer,
              let scrollView = browserScrollView else { return }

        // Remove all existing subviews
        gridContainer.subviews.forEach { $0.removeFromSuperview() }

        // Check if no results
        if filteredWallpaperData.isEmpty {
            let noResultsLabel = NSTextField(labelWithString: "Nothing found")
            noResultsLabel.font = NSFont.systemFont(ofSize: 18)
            noResultsLabel.textColor = .secondaryLabelColor
            noResultsLabel.alignment = .center
            noResultsLabel.frame = NSRect(x: 0, y: scrollView.frame.height / 2 - 15, width: scrollView.frame.width, height: 30)
            gridContainer.addSubview(noResultsLabel)
            gridContainer.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width, height: scrollView.frame.height)
            return
        }

        // Grid configuration
        let columns = 3
        let itemSpacing: CGFloat = 20
        let containerWidth = scrollView.frame.width
        let itemWidth = (containerWidth - CGFloat(columns + 1) * itemSpacing) / CGFloat(columns)
        let itemHeight = itemWidth * 1.5 // 1.5 aspect ratio (twice as tall)

        // Calculate total rows
        let totalItems = filteredWallpaperData.count
        let rows = (totalItems + columns - 1) / columns
        let searchText = searchField?.stringValue ?? ""
        let loadMoreButtonHeight: CGFloat = searchText.isEmpty ? 60 : 0
        let totalHeight = CGFloat(rows) * (itemHeight + itemSpacing) + itemSpacing + loadMoreButtonHeight

        // Resize grid container
        gridContainer.frame = NSRect(x: 0, y: 0, width: containerWidth, height: totalHeight)

        // Create grid items
        for (index, wallpaper) in filteredWallpaperData.enumerated() {
            let row = index / columns
            let col = index % columns
            let x = itemSpacing + CGFloat(col) * (itemWidth + itemSpacing)
            let y = totalHeight - (CGFloat(row + 1) * (itemHeight + itemSpacing))

            let itemView = createWallpaperThumbnail(wallpaper: wallpaper, frame: NSRect(x: x, y: y, width: itemWidth, height: itemHeight))
            gridContainer.addSubview(itemView)
        }

        // Add "Load More" button at bottom only if not filtering
        if searchText.isEmpty {
            let buttonWidth: CGFloat = 200
            let buttonHeight: CGFloat = 40
            let loadMoreButton = NSButton(frame: NSRect(
                x: (containerWidth - buttonWidth) / 2,
                y: 10,
                width: buttonWidth,
                height: buttonHeight
            ))
            loadMoreButton.title = "Load More"
            loadMoreButton.bezelStyle = .rounded
            loadMoreButton.target = self
            loadMoreButton.action = #selector(loadMoreWallpapers)
            gridContainer.addSubview(loadMoreButton)
        }
    }

    func getAverageColor(from image: NSImage) -> NSColor? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var totalRed: CGFloat = 0
        var totalGreen: CGFloat = 0
        var totalBlue: CGFloat = 0
        var pixelCount: CGFloat = 0

        // Sample every 10th pixel for performance
        for x in stride(from: 0, to: width, by: 10) {
            for y in stride(from: 0, to: height, by: 10) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                totalRed += color.redComponent
                totalGreen += color.greenComponent
                totalBlue += color.blueComponent
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else { return nil }

        let avgRed = totalRed / pixelCount
        let avgGreen = totalGreen / pixelCount
        let avgBlue = totalBlue / pixelCount

        return NSColor(red: avgRed, green: avgGreen, blue: avgBlue, alpha: 1.0)
    }

    func createWallpaperThumbnail(wallpaper: [String: Any], frame: NSRect) -> NSView {
        let itemView = HoverScaleView(frame: frame)
        itemView.wantsLayer = true
        itemView.layer?.backgroundColor = NSColor.darkGray.cgColor
        itemView.layer?.cornerRadius = 8
        // Default anchor point is already (0.5, 0.5) = center

        // Store wallpaper ID in the view
        if let wallpaperId = wallpaper["id"] as? Int {
            itemView.wallpaperId = wallpaperId
        }

        // Calculate heights
        let thumbnailHeight = frame.height * 0.8
        let overlayHeight = frame.height * 0.2

        // Create clipping container with top-only rounded corners - positioned at top, 80% of height
        let clipContainer = NSView(frame: NSRect(x: 0, y: overlayHeight, width: frame.width, height: thumbnailHeight))
        clipContainer.wantsLayer = true
        clipContainer.layer?.cornerRadius = 8
        clipContainer.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] // Top corners only
        clipContainer.layer?.masksToBounds = true
        itemView.addSubview(clipContainer)

        // Add overlay at bottom 20% (will be filled with average color later)
        let overlayView = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: overlayHeight))
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.darkGray.cgColor // Default color, will be replaced
        itemView.addSubview(overlayView)

        // Load thumbnail image asynchronously
        if let thumbnailURLString = wallpaper["thumbnail"] as? String,
           let thumbnailURL = URL(string: thumbnailURLString) {
            URLSession.shared.dataTask(with: thumbnailURL) { data, _, error in
                guard let data = data, error == nil, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    // Calculate average color from thumbnail
                    let averageColor = self.getAverageColor(from: image) ?? NSColor.darkGray
                    overlayView.layer?.backgroundColor = averageColor.cgColor

                    // Calculate aspect-fill frame from top
                    let imageSize = image.size
                    let containerSize = clipContainer.bounds.size
                    let imageAspect = imageSize.width / imageSize.height
                    let containerAspect = containerSize.width / containerSize.height

                    var imageFrame = clipContainer.bounds
                    if imageAspect > containerAspect {
                        // Image is wider - fit height, center width
                        let scaledWidth = containerSize.height * imageAspect
                        imageFrame = NSRect(
                            x: (containerSize.width - scaledWidth) / 2,
                            y: 0,
                            width: scaledWidth,
                            height: containerSize.height
                        )
                    } else {
                        // Image is taller - fit width, align to top
                        let scaledHeight = containerSize.width / imageAspect
                        imageFrame = NSRect(
                            x: 0,
                            y: containerSize.height - scaledHeight, // Align to top in macOS coordinates
                            width: containerSize.width,
                            height: scaledHeight
                        )
                    }

                    let imageView = NSImageView(frame: imageFrame)
                    imageView.image = image
                    imageView.imageScaling = .scaleAxesIndependently
                    clipContainer.addSubview(imageView)
                }
            }.resume()
        }

        // Add white text label with wallpaper name (vertically centered)
        if let name = wallpaper["name"] as? String {
            let label = NSTextField(labelWithString: name)
            label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            label.textColor = .white
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            let labelHeight: CGFloat = 18
            label.frame = NSRect(x: 10, y: (overlayHeight - labelHeight) / 2, width: frame.width - 20, height: labelHeight)
            overlayView.addSubview(label)
        }

        // Tags removed from thumbnails

        // Add click gesture to download
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(wallpaperThumbnailClicked(_:)))
        itemView.addGestureRecognizer(clickGesture)

        // Store wallpaper data in the view
        itemView.identifier = NSUserInterfaceItemIdentifier(rawValue: "wallpaper_\(wallpaper["id"] ?? 0)")

        return itemView
    }

    @objc func scrollViewDidEndLiveScroll(_ notification: Notification) {
        // Check all cells to see if mouse is still inside after scroll
        guard let gridContainer = browserGridContainer,
              let window = window else { return }

        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let windowPoint = window.contentView?.convert(mouseLocation, from: nil) ?? .zero

        for subview in gridContainer.subviews {
            if let hoverView = subview as? HoverScaleView {
                let localPoint = hoverView.convert(windowPoint, from: window.contentView)
                if !hoverView.bounds.contains(localPoint) && hoverView.isMouseInside {
                    hoverView.isMouseInside = false
                    hoverView.resetImmediately() // Immediate reset, no animation
                }
            }
        }
    }

    @objc func loadMoreWallpapers() {
        fetchWallpapers(page: currentPage + 1)
    }

    @objc func wallpaperThumbnailClicked(_ sender: NSClickGestureRecognizer) {
        guard let itemView = sender.view,
              let identifier = itemView.identifier?.rawValue,
              let idString = identifier.components(separatedBy: "_").last,
              let wallpaperID = Int(idString) else { return }

        // Find wallpaper data
        guard let wallpaper = wallpaperData.first(where: { ($0["id"] as? Int) == wallpaperID }) else { return }

        // Download wallpaper
        if let urlString = wallpaper["wallpaper"] as? String,
           let name = wallpaper["name"] as? String,
           let type = wallpaper["type"] as? String {
            downloadWallpaperFromAPI(urlString: urlString, name: name, type: type)
        }
    }

    @objc func tagButtonClicked(_ sender: NSClickGestureRecognizer) {
        guard let tagView = sender.view,
              let label = tagView.subviews.first as? NSTextField else { return }

        // Set search field to tag name and perform search
        searchField?.stringValue = label.stringValue
        filterWallpapers()
    }

    @objc func setButtonClicked(_ sender: NSClickGestureRecognizer) {
        print("setButtonClicked: sender.view = \(String(describing: sender.view))")

        guard let setButton = sender.view else {
            print("setButtonClicked: No sender.view")
            return
        }

        print("setButtonClicked: setButton.superview = \(String(describing: setButton.superview))")

        guard let overlayView = setButton.superview else {
            print("setButtonClicked: No overlay view")
            return
        }

        print("setButtonClicked: overlayView.superview = \(String(describing: overlayView.superview))")

        guard let itemView = overlayView.superview as? HoverScaleView else {
            print("setButtonClicked: Could not cast to HoverScaleView")
            return
        }

        print("setButtonClicked: itemView.wallpaperId = \(String(describing: itemView.wallpaperId))")

        guard let wallpaperId = itemView.wallpaperId else {
            print("Could not get wallpaper ID from set button")
            return
        }

        print("Set button clicked for wallpaper ID: \(wallpaperId)")

        // Check if already downloaded by checking ID file
        guard let assetsFolderURL = assetsFolderURL else { return }
        let idsFolder = assetsFolderURL.appendingPathComponent("IDs")
        let idFilePath = idsFolder.appendingPathComponent("\(wallpaperId)")

        if FileManager.default.fileExists(atPath: idFilePath.path) {
            // Already downloaded, set it immediately
            print("Wallpaper already downloaded, setting it now")
            if let assetURL = findAssetURLByWallpaperId(wallpaperId) {
                setAsWallpaperWithPath(assetURL: assetURL)
            }
        } else {
            // Not downloaded yet, download first then set
            print("Wallpaper not downloaded, downloading first")
            downloadAndSetWallpaper(wallpaperId: wallpaperId)
        }
    }

    func downloadAndSetWallpaper(wallpaperId: Int) {
        downloadWallpaperZip(wallpaperId: wallpaperId, completion: { [weak self] success, assetURL in
            if success, let assetURL = assetURL {
                self?.setAsWallpaperWithPath(assetURL: assetURL)
            }
        })
    }

    func downloadAndPlayInCell(wallpaperId: Int, cellView: HoverScaleView) {
        // Stop all other cells first
        stopAllCellPlayback()

        // Mark this cell as currently playing
        currentlyPlayingCellId = wallpaperId

        downloadWallpaperZip(wallpaperId: wallpaperId, completion: { [weak self] success, assetURL in
            guard let self = self else { return }

            if success, let assetURL = assetURL {
                // Play content in this cell
                self.playContentInCell(assetURL: assetURL, cellView: cellView, wallpaperId: wallpaperId)
            }
        })
    }

    func stopAllCellPlayback() {
        // Stop playback in all cells and reset to thumbnails
        guard let gridContainer = browserGridContainer else { return }

        for subview in gridContainer.subviews {
            if let cellView = subview as? HoverScaleView {
                stopCellPlayback(cellView: cellView)
            }
        }

        // Clear all stored renderers and view models
        cellRenderers.removeAll()
        cellRiveViewModels.removeAll()

        currentlyPlayingCellId = nil
    }

    func stopCellPlayback(cellView: HoverScaleView) {
        // Find the clipContainer which is the first subview
        guard let clipContainer = cellView.subviews.first else { return }

        // Find and remove any player/renderer/rive views
        for subview in clipContainer.subviews {
            // Remove the playback view
            if subview.identifier?.rawValue == "playback_view" {
                // Stop AVPlayer if present
                if let containerView = subview as? NSView,
                   let layer = containerView.layer,
                   let playerLayer = layer.sublayers?.first(where: { $0 is AVPlayerLayer }) as? AVPlayerLayer {
                    playerLayer.player?.pause()
                    playerLayer.player = nil
                }

                // Stop MTKView (shader) if present
                for sub in subview.subviews {
                    if let metalView = sub as? MTKView {
                        metalView.delegate = nil
                    }
                }

                subview.removeFromSuperview()
            }
        }
    }

    func playContentInCell(assetURL: URL, cellView: HoverScaleView, wallpaperId: Int) {
        // Find the clipContainer which is the first subview
        guard let clipContainer = cellView.subviews.first else {
            print("playContentInCell: No clipContainer found")
            return
        }

        print("playContentInCell: Playing \(assetURL.lastPathComponent) in cell for wallpaper \(wallpaperId)")

        // Stop any existing playback in this cell
        stopCellPlayback(cellView: cellView)

        let ext = assetURL.pathExtension.lowercased()
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let gifExtensions = ["gif"]
        let shaderExtensions = ["msl"]
        let animationExtensions = ["riv"]

        print("playContentInCell: Extension is \(ext), clipContainer bounds: \(clipContainer.bounds)")

        // Create a container view for playback that fills the clipContainer
        let playbackView = NSView(frame: clipContainer.bounds)
        playbackView.wantsLayer = true
        playbackView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        playbackView.identifier = NSUserInterfaceItemIdentifier("playback_view")

        if videoExtensions.contains(ext) {
            // Play video
            let playerLayer = AVPlayerLayer()
            playerLayer.frame = playbackView.bounds
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

            let player = AVPlayer(url: assetURL)
            player.isMuted = true
            playerLayer.player = player
            playbackView.layer?.addSublayer(playerLayer)

            // Auto-loop video
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }

            player.play()

        } else if gifExtensions.contains(ext) {
            // Play GIF with aspect-fill scaling
            if let gifImage = NSImage(contentsOf: assetURL) {
                let imageSize = gifImage.size
                let containerSize = playbackView.bounds.size
                let imageAspect = imageSize.width / imageSize.height
                let containerAspect = containerSize.width / containerSize.height

                var imageFrame = playbackView.bounds
                if imageAspect > containerAspect {
                    // Image is wider - fit height, center width
                    let scaledWidth = containerSize.height * imageAspect
                    imageFrame = NSRect(
                        x: (containerSize.width - scaledWidth) / 2,
                        y: 0,
                        width: scaledWidth,
                        height: containerSize.height
                    )
                } else {
                    // Image is taller - fit width, center height
                    let scaledHeight = containerSize.width / imageAspect
                    imageFrame = NSRect(
                        x: 0,
                        y: (containerSize.height - scaledHeight) / 2,
                        width: containerSize.width,
                        height: scaledHeight
                    )
                }

                let gifImageView = NSImageView(frame: imageFrame)
                gifImageView.image = gifImage
                gifImageView.imageScaling = .scaleAxesIndependently
                gifImageView.animates = true
                playbackView.addSubview(gifImageView)
            }

        } else if shaderExtensions.contains(ext) {
            // Play shader - exactly like home screen
            guard let device = MTLCreateSystemDefaultDevice(),
                  let shaderSource = try? String(contentsOf: assetURL, encoding: .utf8) else {
                return
            }

            let metalView = MTKView(frame: playbackView.bounds, device: device)
            metalView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]

            let renderer = ShaderRenderer(device: device, shaderSource: shaderSource)
            cellRenderers[wallpaperId] = renderer  // Store to prevent deallocation
            metalView.delegate = renderer

            playbackView.addSubview(metalView)

        } else if animationExtensions.contains(ext) {
            // Play Rive animation with aspect-fill (cover) fit
            let viewModel = RiveViewModel(
                webURL: assetURL.absoluteString,
                fit: .cover,
                alignment: .center,
                loadCdn: false
            )
            cellRiveViewModels[wallpaperId] = viewModel  // Store to prevent deallocation

            let riveView = viewModel.createRiveView()
            riveView.frame = playbackView.bounds
            riveView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
            riveView.wantsLayer = true

            playbackView.addSubview(riveView)

            // Start playing
            viewModel.play(loop: RiveLoop.loop)

            // Set volume to 0 multiple times with delays
            for i in 0...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak viewModel] in
                    viewModel?.riveModel?.volume = 0.0
                }
            }
        }

        // Add playback view on top of thumbnail in clipContainer
        clipContainer.addSubview(playbackView)
        print("playContentInCell: Added playback view to clipContainer, subviews count: \(clipContainer.subviews.count)")

        // Hide play button since content is now playing
        cellView.playButtonView?.alphaValue = 0
    }

    func findAssetURLByWallpaperId(_ wallpaperId: Int) -> URL? {
        guard let assetsFolderURL = assetsFolderURL else {
            print("findAssetURLByWallpaperId: No assets folder URL")
            return nil
        }

        // Read the path from the ID file
        let idsFolder = assetsFolderURL.appendingPathComponent("IDs")
        let idFilePath = idsFolder.appendingPathComponent("\(wallpaperId)")

        guard let assetPath = try? String(contentsOf: idFilePath, encoding: .utf8) else {
            print("findAssetURLByWallpaperId: Could not read ID file for \(wallpaperId)")
            return nil
        }

        let assetURL = URL(fileURLWithPath: assetPath)
        print("findAssetURLByWallpaperId: Found asset at: \(assetPath)")
        return assetURL
    }

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        filterWallpapers()
    }

    var availableTags: [String] = []

    func displayGlobalTags() {
        // Collect first 3 tags from each wallpaper
        var allTags: [String] = []
        for wallpaper in wallpaperData {
            if let tags = wallpaper["tags"] as? [[String: Any]] {
                let tagNames = tags.prefix(3).compactMap { $0["name"] as? String }
                allTags.append(contentsOf: tagNames)
            }
        }

        // Remove duplicates and limit to 100
        var uniqueTags = Array(Set(allTags)).sorted()
        uniqueTags = Array(uniqueTags.prefix(100))

        // Store available tags
        availableTags = uniqueTags
    }

    @objc func tagsButtonClicked(_ sender: NSButton) {
        // Create popover content view with checkboxes in two columns
        let columnWidth: CGFloat = 180
        let popoverWidth = columnWidth * 2 + 30
        let tagsPerColumn = (availableTags.count + 1) / 2
        let rowHeight: CGFloat = 25
        let contentHeight = CGFloat(tagsPerColumn) * rowHeight

        let popoverView = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: min(400, contentHeight + 20)))

        let scrollView = NSScrollView(frame: popoverView.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth - 20, height: contentHeight))

        var column = 0
        var yOffset: CGFloat = contentHeight - rowHeight + 5

        for (index, tag) in availableTags.enumerated() {
            let xOffset = CGFloat(column) * (columnWidth + 10) + 10
            let checkbox = NSButton(checkboxWithTitle: tag, target: self, action: #selector(tagCheckboxChanged(_:)))
            checkbox.frame = NSRect(x: xOffset, y: yOffset, width: columnWidth, height: 20)
            checkbox.state = selectedTags.contains(tag) ? .on : .off
            contentView.addSubview(checkbox)

            // Move to next row in current column
            yOffset -= rowHeight

            // Switch to second column when first column is filled
            if (index + 1) == tagsPerColumn && column == 0 {
                column = 1
                yOffset = contentHeight - rowHeight + 5
            }
        }

        scrollView.documentView = contentView
        popoverView.addSubview(scrollView)

        let popover = NSPopover()
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = popoverView
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        tagsPopover = popover
    }

    @objc func typeButtonClicked(_ sender: NSButton) {
        let types = ["Image", "Video", "Shader", "Animation"]
        let popoverView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: CGFloat(types.count * 25 + 20)))

        let contentView = NSView(frame: NSRect(x: 0, y: 5, width: 180, height: CGFloat(types.count * 25)))

        var yOffset: CGFloat = CGFloat(types.count * 25 - 20)
        for type in types {
            let checkbox = NSButton(checkboxWithTitle: type, target: self, action: #selector(typeCheckboxChanged(_:)))
            checkbox.frame = NSRect(x: 10, y: yOffset, width: 170, height: 20)
            checkbox.state = selectedTypes.contains(type) ? .on : .off
            contentView.addSubview(checkbox)
            yOffset -= 25
        }

        popoverView.addSubview(contentView)

        let popover = NSPopover()
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = popoverView
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        typePopover = popover
    }

    @objc func typeCheckboxChanged(_ sender: NSButton) {
        let type = sender.title
        if sender.state == .on {
            selectedTypes.insert(type)
            print("Type selected: \(type), selectedTypes: \(selectedTypes)")
        } else {
            selectedTypes.remove(type)
            print("Type deselected: \(type), selectedTypes: \(selectedTypes)")
        }
        filterWallpapers()
    }

    @objc func tagCheckboxChanged(_ sender: NSButton) {
        let tag = sender.title
        if sender.state == .on {
            selectedTags.insert(tag)
            print("Tag selected: \(tag), selectedTags: \(selectedTags)")
        } else {
            selectedTags.remove(tag)
            print("Tag deselected: \(tag), selectedTags: \(selectedTags)")
        }
        filterWallpapers()
    }

    @objc func sortButtonClicked(_ sender: NSButton) {
        let sortOptions = ["A-Z", "Z-A", "Newest First", "Oldest First"]
        let popoverView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: CGFloat(sortOptions.count * 25 + 20)))

        let contentView = NSView(frame: NSRect(x: 0, y: 5, width: 180, height: CGFloat(sortOptions.count * 25)))

        var yOffset: CGFloat = CGFloat(sortOptions.count * 25 - 20)
        for option in sortOptions {
            let radioButton = NSButton(radioButtonWithTitle: option, target: self, action: #selector(sortRadioChanged(_:)))
            radioButton.frame = NSRect(x: 10, y: yOffset, width: 170, height: 20)
            radioButton.state = (selectedSort == option) ? .on : .off
            contentView.addSubview(radioButton)
            yOffset -= 25
        }

        popoverView.addSubview(contentView)

        let popover = NSPopover()
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = popoverView
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        sortPopover = popover
    }

    @objc func sortRadioChanged(_ sender: NSButton) {
        let option = sender.title
        selectedSort = option
        print("Sort selected: \(option)")

        // Update all radio buttons in the popover
        if let popover = sortPopover,
           let contentView = popover.contentViewController?.view.subviews.first {
            for subview in contentView.subviews {
                if let radioButton = subview as? NSButton {
                    radioButton.state = (radioButton.title == option) ? .on : .off
                }
            }
        }

        filterWallpapers()
    }

    func sortWallpapers(_ wallpapers: [[String: Any]], by sortOption: String) -> [[String: Any]] {
        switch sortOption {
        case "A-Z":
            return wallpapers.sorted { wp1, wp2 in
                let name1 = (wp1["name"] as? String ?? "").lowercased()
                let name2 = (wp2["name"] as? String ?? "").lowercased()
                return name1 < name2
            }
        case "Z-A":
            return wallpapers.sorted { wp1, wp2 in
                let name1 = (wp1["name"] as? String ?? "").lowercased()
                let name2 = (wp2["name"] as? String ?? "").lowercased()
                return name1 > name2
            }
        case "Newest First":
            return wallpapers.sorted { wp1, wp2 in
                let date1 = parseDate(wp1["created_at"] as? String ?? "")
                let date2 = parseDate(wp2["created_at"] as? String ?? "")
                return date1 > date2
            }
        case "Oldest First":
            return wallpapers.sorted { wp1, wp2 in
                let date1 = parseDate(wp1["created_at"] as? String ?? "")
                let date2 = parseDate(wp2["created_at"] as? String ?? "")
                return date1 < date2
            }
        default:
            return wallpapers
        }
    }

    func parseDate(_ dateString: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            return date
        }

        // Fallback: return distant past for invalid dates
        return Date.distantPast
    }

    func downloadWallpaperZip(wallpaperId: Int, completion: ((Bool, URL?) -> Void)? = nil) {
        // Find wallpaper in data to get the zip URL
        print("Looking for wallpaper ID: \(wallpaperId) in \(wallpaperData.count) wallpapers")

        guard let wallpaper = wallpaperData.first(where: { ($0["id"] as? Int) == wallpaperId }) else {
            print("Could not find wallpaper for ID: \(wallpaperId)")
            print("Available IDs: \(wallpaperData.compactMap { $0["id"] as? Int })")
            completion?(false, nil)
            return
        }

        // Fast check BEFORE downloading: check if ID file exists
        if let assetsFolderURL = assetsFolderURL {
            let idsFolder = assetsFolderURL.appendingPathComponent("IDs")
            let idFilePath = idsFolder.appendingPathComponent("\(wallpaperId)")

            if FileManager.default.fileExists(atPath: idFilePath.path) {
                print("Fast check: already there")
                // Find and return the asset URL
                let assetURL = findAssetURLByWallpaperId(wallpaperId)
                completion?(true, assetURL)
                return
            }

            print("Fast check: not found, proceeding with download")
        }

        guard let zipURL = wallpaper["wallpaper_file"] as? String else {
            print("Wallpaper data doesn't have 'wallpaper_file' field")
            print("Available keys: \(wallpaper.keys)")
            completion?(false, nil)
            return
        }

        print("Downloading wallpaper from: \(zipURL)")

        // First, record the download stat
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let token = md5Hash(timestamp + "wall")

        if let statsURL = URL(string: "https://backend.wallpics.app/api/wallpapers/\(wallpaperId)/download") {
            var request = URLRequest(url: statsURL)
            request.httpMethod = "POST"
            request.setValue(timestamp, forHTTPHeaderField: "x-auth")
            request.setValue(token, forHTTPHeaderField: "x-token")
            if let guestId = guestId {
                request.setValue(guestId, forHTTPHeaderField: "x-guest-id")
            }

            // Fire and forget - don't wait for response
            URLSession.shared.dataTask(with: request).resume()
        }

        // Download the actual zip file
        downloadZipFromURL(urlString: zipURL, wallpaperId: wallpaperId, completion: completion)
    }

    func downloadZipFromURL(urlString: String, wallpaperId: Int, completion: ((Bool, URL?) -> Void)? = nil) {
        guard let url = URL(string: urlString) else {
            print("Invalid download URL: \(urlString)")
            completion?(false, nil)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                print("Zip download error: \(error.localizedDescription)")
                completion?(false, nil)
                return
            }

            guard let data = data else {
                print("No zip data received")
                completion?(false, nil)
                return
            }

            print("Downloaded zip data: \(data.count) bytes")
            self?.extractAndSaveWallpaperZip(data: data, wallpaperId: wallpaperId, completion: completion)
        }.resume()
    }

    func extractAndSaveWallpaperZip(data: Data, wallpaperId: Int, completion: ((Bool, URL?) -> Void)? = nil) {
        // Create temp directory for extraction
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Write zip data to temp file
            let zipPath = tempDir.appendingPathComponent("wallpaper.zip")
            try data.write(to: zipPath)

            // First, peek inside the zip to get the filename without extracting
            let listTask = Process()
            listTask.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            listTask.arguments = ["-Z1", zipPath.path]

            let pipe = Pipe()
            listTask.standardOutput = pipe
            try listTask.run()
            listTask.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let fileList = String(data: outputData, encoding: .utf8)?.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("__MACOSX") && !$0.hasPrefix(".") } ?? []

            guard let firstFile = fileList.first else {
                print("Error: Could not read zip contents")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(false, nil)
                return
            }

            // Get filename (handle both direct files and files in directories)
            let fileName = URL(fileURLWithPath: firstFile).lastPathComponent
            let ext = URL(fileURLWithPath: firstFile).pathExtension.lowercased()

            // Determine destination folder based on extension
            guard let assetsFolder = assetsFolderURL else {
                print("Assets folder not available")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(false, nil)
                return
            }

            let videoExtensions = ["mp4", "mov", "m4v", "avi"]
            let imageExtensions = ["jpg", "jpeg", "png", "heic", "gif"]
            let animationExtensions = ["riv"]
            let shaderExtensions = ["msl"]

            let destinationFolder: URL
            if videoExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Videos")
            } else if imageExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Images")
            } else if animationExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Animations")
            } else if shaderExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Shaders")
            } else {
                print("Unknown file type: \(ext)")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(false, nil)
                return
            }

            // Check if file already exists in destination
            let destinationPath = destinationFolder.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destinationPath.path) {
                print("Already downloaded: \(fileName)")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(true, nil)
                return
            }

            // Extract zip
            let extractDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-q", zipPath.path, "-d", extractDir.path]
            try task.run()
            task.waitUntilExit()

            // Check extracted contents
            let allContents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)

            print("Extracted \(allContents.count) files:")
            for file in allContents {
                print("  - \(file.lastPathComponent)")
            }

            // Filter out __MACOSX and other metadata
            let contents = allContents.filter { !$0.lastPathComponent.hasPrefix("__MACOSX") && !$0.lastPathComponent.hasPrefix(".") }

            guard contents.count == 1 else {
                print("Error: Expected 1 file in zip after filtering, got \(contents.count)")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(false, nil)
                return
            }

            let extractedFile = contents[0]
            let extractedFileName = extractedFile.lastPathComponent
            let extractedExt = extractedFile.pathExtension.lowercased()

            print("Extracted file: \(extractedFileName) with extension: \(extractedExt)")

            // Check if it's a directory
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: extractedFile.path, isDirectory: &isDirectory), isDirectory.boolValue {
                print("Extracted item is a directory, looking inside...")
                let dirContents = try FileManager.default.contentsOfDirectory(at: extractedFile, includingPropertiesForKeys: nil)
                    .filter { !$0.lastPathComponent.hasPrefix(".") }

                guard dirContents.count == 1 else {
                    print("Directory contains \(dirContents.count) files, expected 1")
                    try? FileManager.default.removeItem(at: tempDir)
                    completion?(false, nil)
                    return
                }

                let actualFile = dirContents[0]
                let actualFileName = actualFile.lastPathComponent
                let actualExt = actualFile.pathExtension.lowercased()

                print("Found actual file in directory: \(actualFileName) with extension: \(actualExt)")

                // Continue with the actual file
                continueExtraction(file: actualFile, fileName: actualFileName, ext: actualExt, tempDir: tempDir, wallpaperId: wallpaperId, completion: completion)
                return
            }

            continueExtraction(file: extractedFile, fileName: extractedFileName, ext: extractedExt, tempDir: tempDir, wallpaperId: wallpaperId, completion: completion)

        } catch {
            print("Error extracting zip: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempDir)
            completion?(false, nil)
        }
    }

    func continueExtraction(file: URL, fileName: String, ext: String, tempDir: URL, wallpaperId: Int, completion: ((Bool, URL?) -> Void)? = nil) {
        do {
            // Determine destination folder based on extension
            guard let assetsFolder = assetsFolderURL else {
                print("Assets folder not available")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(false, nil)
                return
            }

            let videoExtensions = ["mp4", "mov", "m4v", "avi"]
            let imageExtensions = ["jpg", "jpeg", "png", "heic"]
            let gifExtensions = ["gif"]
            let animationExtensions = ["riv"]
            let shaderExtensions = ["msl"]

            let destinationFolder: URL
            if videoExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Videos")
            } else if imageExtensions.contains(ext) || gifExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Images")
            } else if animationExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Animations")
            } else if shaderExtensions.contains(ext) {
                destinationFolder = assetsFolder.appendingPathComponent("Shaders")
            } else {
                print("Unknown file type: \(ext)")
                print("Full file path: \(file.path)")
                try? FileManager.default.removeItem(at: tempDir)
                completion?(false, nil)
                return
            }

            // Create destination folder if needed
            try? FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

            // Move file to destination
            let destinationPath = destinationFolder.appendingPathComponent(fileName)

            // Remove existing file if present
            try? FileManager.default.removeItem(at: destinationPath)

            try FileManager.default.moveItem(at: file, to: destinationPath)

            print("Successfully saved wallpaper to: \(destinationPath.path)")

            // Download and save thumbnail to FirstFrames folder
            // Skip for regular images (jpg, jpeg, png, heic), but include GIFs
            let shouldSaveThumbnail = videoExtensions.contains(ext) || gifExtensions.contains(ext) || animationExtensions.contains(ext) || shaderExtensions.contains(ext)

            if shouldSaveThumbnail {
                downloadAndSaveThumbnail(wallpaperId: wallpaperId, fileName: fileName, assetsFolder: assetsFolder)
            }

            // Create ID file with the asset filename inside
            let idsFolder = assetsFolder.appendingPathComponent("IDs")
            let idFilePath = idsFolder.appendingPathComponent("\(wallpaperId)")
            try? destinationPath.path.write(to: idFilePath, atomically: true, encoding: .utf8)
            print("Created ID marker: \(wallpaperId) with path: \(destinationPath.path)")

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)

            // Call completion on main thread with the destination path
            DispatchQueue.main.async {
                completion?(true, destinationPath)
            }

        } catch {
            print("Error: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempDir)
            DispatchQueue.main.async {
                completion?(false, nil)
            }
        }
    }

    func downloadAndSaveThumbnail(wallpaperId: Int, fileName: String, assetsFolder: URL) {
        // Find wallpaper data to get thumbnail URL
        guard let wallpaper = wallpaperData.first(where: { ($0["id"] as? Int) == wallpaperId }),
              let thumbnailURLString = wallpaper["thumbnail"] as? String,
              let thumbnailURL = URL(string: thumbnailURLString) else {
            print("Could not find thumbnail URL for wallpaper ID: \(wallpaperId)")
            return
        }

        // Download thumbnail
        URLSession.shared.dataTask(with: thumbnailURL) { data, response, error in
            guard let data = data, error == nil else {
                print("Failed to download thumbnail: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            // Determine thumbnail extension from URL
            let thumbnailExt = thumbnailURL.pathExtension.lowercased()

            // Only convert heic and webp to jpg, otherwise keep original format
            let needsConversion = thumbnailExt == "heic" || thumbnailExt == "webp"
            let finalExt: String
            let finalData: Data

            if needsConversion {
                // Convert heic/webp to jpg
                guard let image = NSImage(data: data),
                      let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                    print("Failed to convert thumbnail from \(thumbnailExt) to JPEG")
                    return
                }
                finalExt = "jpg"
                finalData = jpegData
            } else {
                // Keep original format
                finalExt = thumbnailExt.isEmpty ? "jpg" : thumbnailExt
                finalData = data
            }

            let firstFramesFolder = assetsFolder.appendingPathComponent("FirstFrames")
            let fileNameWithoutExt = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            let thumbnailPath = firstFramesFolder.appendingPathComponent("\(fileNameWithoutExt).\(finalExt)")

            do {
                try finalData.write(to: thumbnailPath)
                print("Saved thumbnail to: \(thumbnailPath.path)")
            } catch {
                print("Failed to save thumbnail: \(error.localizedDescription)")
            }
        }.resume()
    }

    func filterWallpapers() {
        let searchText = searchField?.stringValue.lowercased() ?? ""

        // Save old results for comparison
        let oldFilteredData = filteredWallpaperData

        // Start with all wallpapers
        var filtered = wallpaperData

        // Filter by search text
        if !searchText.isEmpty {
            filtered = filtered.filter { wallpaper in
                // Check name
                if let name = wallpaper["name"] as? String,
                   name.lowercased().contains(searchText) {
                    return true
                }

                // Check tags
                if let tags = wallpaper["tags"] as? [[String: Any]] {
                    for tag in tags {
                        if let tagName = tag["name"] as? String,
                           tagName.lowercased().contains(searchText) {
                            return true
                        }
                    }
                }

                return false
            }
        }

        // Filter by selected types (must have ANY of the selected types)
        if !selectedTypes.isEmpty {
            filtered = filtered.filter { wallpaper in
                guard let wallpaperId = wallpaper["id"] as? Int else { return false }

                // Check if downloaded by looking for ID file
                guard let assetsFolderURL = self.assetsFolderURL else { return false }
                let idsFolder = assetsFolderURL.appendingPathComponent("IDs")
                let idFilePath = idsFolder.appendingPathComponent("\(wallpaperId)")

                guard FileManager.default.fileExists(atPath: idFilePath.path),
                      let assetPath = try? String(contentsOf: idFilePath, encoding: .utf8) else {
                    return false
                }

                let assetURL = URL(fileURLWithPath: assetPath)
                let ext = assetURL.pathExtension.lowercased()

                // Determine type from extension
                let wallpaperType: String
                if ext == "msl" {
                    wallpaperType = "Shader"
                } else if ext == "riv" {
                    wallpaperType = "Animation"
                } else if ["jpg", "jpeg", "png", "heic", "gif"].contains(ext) {
                    wallpaperType = "Image"
                } else {
                    wallpaperType = "Video"
                }

                return selectedTypes.contains(wallpaperType)
            }
        }

        // Filter by selected tags (must have ANY of the selected tags)
        if !selectedTags.isEmpty {
            filtered = filtered.filter { wallpaper in
                guard let tags = wallpaper["tags"] as? [[String: Any]] else { return false }
                let wallpaperTagNames = Set(tags.compactMap { $0["name"] as? String })
                return !selectedTags.isDisjoint(with: wallpaperTagNames)
            }
        }

        // Apply sorting
        if !selectedSort.isEmpty {
            filtered = sortWallpapers(filtered, by: selectedSort)
        }

        filteredWallpaperData = filtered

        // Compare old and new filtered results
        let resultsChanged: Bool
        if oldFilteredData.count != filteredWallpaperData.count {
            resultsChanged = true
        } else {
            // Check if IDs match
            let oldIds = oldFilteredData.compactMap { $0["id"] as? Int }
            let newIds = filteredWallpaperData.compactMap { $0["id"] as? Int }
            resultsChanged = oldIds != newIds
        }

        // Only refresh if results changed
        if resultsChanged {
            displayWallpapers()

            // Scroll to top
            if let scrollView = browserScrollView, let documentView = scrollView.documentView {
                let topPoint = NSPoint(x: 0, y: documentView.frame.height - scrollView.contentView.bounds.height)
                scrollView.contentView.scroll(to: topPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    func createCreateView(frame: NSRect) {
        createView = NSView(frame: frame)
        createView?.wantsLayer = true
        createView?.autoresizingMask = [.width, .height]

        // Create huge centered clickable view
        let buttonWidth: CGFloat = frame.width * 0.8
        let buttonHeight: CGFloat = frame.height * 0.375  // 0.3 * 1.25
        let buttonView = NSView(frame: NSRect(
            x: (frame.width - buttonWidth) / 2,
            y: (frame.height - buttonHeight) / 2,
            width: buttonWidth,
            height: buttonHeight
        ))
        buttonView.wantsLayer = true
        buttonView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        buttonView.layer?.cornerRadius = 12
        buttonView.layer?.borderWidth = 2
        buttonView.layer?.borderColor = NSColor.separatorColor.cgColor
        buttonView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

        // Add text label inside
        let label = NSTextField(wrappingLabelWithString: "Click to import asset to create your own wallpaper (.jpg, .png, .gif, .heic, .mp4, .mov, \n.m4v, .avi, .mkv, .msl, .riv)")
        label.font = NSFont.systemFont(ofSize: 45, weight: .bold)  // 1.5 times more (32 * 1.5 = 48)
        label.textColor = NSColor.labelColor
        label.alignment = .center
        label.frame = NSRect(x: 40, y: 40, width: buttonWidth - 80, height: buttonHeight - 100)
        label.autoresizingMask = [.width, .height]
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        buttonView.addSubview(label)

        // Add click gesture
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(importAsset))
        buttonView.addGestureRecognizer(clickGesture)

        createView?.addSubview(buttonView)
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
            // Show notification label on home screen
            notificationLabel?.isHidden = false
        case 1:
            showView(browserView)
            // Hide notification label on browser screen
            notificationLabel?.isHidden = true
        case 2:
            showView(createView)
            // Hide notification label on create screen
            notificationLabel?.isHidden = true
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

        let importItem = NSMenuItem(title: "Import", action: #selector(importAsset), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        // Play/Pause menu item (hidden by default)
        playPauseMenuItem = NSMenuItem(title: "Stop", action: #selector(togglePlayPause), keyEquivalent: "")
        playPauseMenuItem?.target = self
        playPauseMenuItem?.isHidden = true
        if let playPauseItem = playPauseMenuItem {
            menu.addItem(playPauseItem)
        }

        menu.addItem(NSMenuItem.separator())

        let exitItem = NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "")
        exitItem.target = self
        menu.addItem(exitItem)

        statusItem?.menu = menu
    }

    func updatePlayPauseMenu() {
        // Hide menu item for static images or no wallpaper
        if currentWallpaperType == .none || currentWallpaperType == .image {
            playPauseMenuItem?.isHidden = true
            return
        }

        // Show menu item and update title
        playPauseMenuItem?.isHidden = false
        playPauseMenuItem?.title = screensaverIsPlaying ? "Stop" : "Play"
    }

    @objc func togglePlayPause() {
        screensaverIsPlaying.toggle()
        updatePlayPauseMenu()

        if screensaverIsPlaying {
            resumeWallpapers()
        } else {
            pauseWallpapers()
        }
    }

    func pauseWallpapers() {
        // Pause videos
        for window in videoWallpaperWindows {
            window.pause()
        }

        // Pause shaders
        for window in shaderWallpaperWindows {
            window.pause()
        }

        // Pause animations
        for window in animationWallpaperWindows {
            window.pause()
        }

        // Pause GIFs
        for window in gifWallpaperWindows {
            window.pause()
        }
    }

    func resumeWallpapers() {
        // Resume videos
        for window in videoWallpaperWindows {
            window.resume()
        }

        // Resume shaders
        for window in shaderWallpaperWindows {
            window.resume()
        }

        // Resume animations
        for window in animationWallpaperWindows {
            window.resume()
        }

        // Resume GIFs
        for window in gifWallpaperWindows {
            window.resume()
        }
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

    func validateShader(shaderSource: String) -> Bool {
        // Hardcoded vertex shader - same as used in ShaderRenderer
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
            float padding;
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

            float2 pos = positions[vertexID];
            out.position = float4(pos, 0.0, 1.0);
            out.uv = pos * 0.5 + 0.5;
            out.uv.y = 1.0 - out.uv.y;

            return out;
        }
        """

        // Combine vertex and fragment shaders
        let combinedSource = vertexShaderSource + "\n" + shaderSource

        // Try to compile
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }

        do {
            let library = try device.makeLibrary(source: combinedSource, options: nil)
            // Check that both functions exist
            guard library.makeFunction(name: "vertexShader") != nil,
                  library.makeFunction(name: "fragmentShader") != nil else {
                return false
            }
            return true
        } catch {
            print("Shader validation failed: \(error)")
            return false
        }
    }

    @objc func importAsset() {
        // Show main window and select home screen
        if window == nil {
            createMainWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Switch to home screen tab
        if let segmentedControl = window?.contentView?.subviews.first(where: { $0 is NSSegmentedControl }) as? NSSegmentedControl {
            segmentedControl.selectedSegment = 0
            showView(homeView)
        }

        guard let assetsFolderURL = assetsFolderURL else { return }

        // Collect all supported extensions
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "bmp", "tiff", "heic"]
        let gifExtensions = ["gif"]
        let shaderExtensions = ["msl"]
        let animationExtensions = ["riv"]
        let allExtensions = videoExtensions + imageExtensions + gifExtensions + shaderExtensions + animationExtensions

        // Create file dialog
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = allExtensions.map { UTType(filenameExtension: $0) }.compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        // Load last directory from imports.txt
        let importsSettingsURL = assetsFolderURL.appendingPathComponent("imports.txt")
        if let lastDirectory = try? String(contentsOf: importsSettingsURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !lastDirectory.isEmpty {
            openPanel.directoryURL = URL(fileURLWithPath: lastDirectory)
        }

        openPanel.begin { [weak self] response in
            guard let self = self, response == .OK, let selectedURL = openPanel.url else { return }

            // Save last directory to imports.txt
            let directoryPath = selectedURL.deletingLastPathComponent().path
            try? directoryPath.write(to: importsSettingsURL, atomically: true, encoding: .utf8)

            // Determine destination folder based on extension
            let ext = selectedURL.pathExtension.lowercased()
            let destinationFolder: String
            if videoExtensions.contains(ext) {
                destinationFolder = "Videos"
            } else if gifExtensions.contains(ext) {
                destinationFolder = "Images"
            } else if shaderExtensions.contains(ext) {
                destinationFolder = "Shaders"
            } else if animationExtensions.contains(ext) {
                destinationFolder = "Animations"
            } else if imageExtensions.contains(ext) {
                destinationFolder = "Images"
            } else {
                return
            }

            let destinationFolderURL = assetsFolderURL.appendingPathComponent(destinationFolder)
            let destinationURL = destinationFolderURL.appendingPathComponent(selectedURL.lastPathComponent)

            // Validate .msl shader before copying
            if shaderExtensions.contains(ext) {
                guard let shaderSource = try? String(contentsOf: selectedURL, encoding: .utf8) else {
                    let alert = NSAlert()
                    alert.messageText = "Invalid .msl shader"
                    alert.informativeText = "Could not read shader file."
                    alert.addButton(withTitle: "OK")
                    alert.alertStyle = .critical
                    alert.runModal()
                    return
                }

                if !self.validateShader(shaderSource: shaderSource) {
                    let alert = NSAlert()
                    alert.messageText = "Invalid .msl shader"
                    alert.informativeText = "Shader failed to compile."
                    alert.addButton(withTitle: "OK")
                    alert.alertStyle = .critical
                    alert.runModal()
                    return
                }
            }

            // Check if file already exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let alert = NSAlert()
                alert.messageText = "File already exists"
                alert.informativeText = "A file with the name \"\(selectedURL.lastPathComponent)\" already exists. Do you want to overwrite it?"
                alert.addButton(withTitle: "Overwrite")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning

                let response = alert.runModal()
                if response != .alertFirstButtonReturn {
                    return
                }

                // Remove existing file
                try? FileManager.default.removeItem(at: destinationURL)
            }

            // Copy file to destination
            do {
                try FileManager.default.copyItem(at: selectedURL, to: destinationURL)
                print("Imported file to: \(destinationURL.path)")

                // Reload home screen with newly imported file as last item
                DispatchQueue.main.async {
                    self.reloadHomeScreenWithNewAsset(destinationURL)
                }

            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = "Could not import file: \(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func reloadHomeScreenWithNewAsset(_ newAssetURL: URL) {
        guard let assetsFolderURL = assetsFolderURL, let contentContainer = contentContainer else { return }

        // Collect all assets from all folders (same as loadHomeAssets)
        var allAssets: [URL] = []

        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
        let imageExtensions = ["jpg", "jpeg", "png", "bmp", "tiff", "heic"]
        let gifExtensions = ["gif"]
        let shaderExtensions = ["msl"]
        let animationExtensions = ["riv"]

        // Videos
        let videosFolder = assetsFolderURL.appendingPathComponent("Videos")
        if let files = try? FileManager.default.contentsOfDirectory(at: videosFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let ext = file.pathExtension.lowercased()
                if videoExtensions.contains(ext) && file != newAssetURL {
                    allAssets.append(file)
                }
            }
        }

        // Images (including GIFs)
        let imagesFolder = assetsFolderURL.appendingPathComponent("Images")
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let ext = file.pathExtension.lowercased()
                if (imageExtensions.contains(ext) || gifExtensions.contains(ext)) && file != newAssetURL {
                    allAssets.append(file)
                }
            }
        }

        // Shaders
        let shadersFolder = assetsFolderURL.appendingPathComponent("Shaders")
        if let files = try? FileManager.default.contentsOfDirectory(at: shadersFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let ext = file.pathExtension.lowercased()
                if shaderExtensions.contains(ext) && file != newAssetURL {
                    allAssets.append(file)
                }
            }
        }

        // Animations
        let animationsFolder = assetsFolderURL.appendingPathComponent("Animations")
        if let files = try? FileManager.default.contentsOfDirectory(at: animationsFolder, includingPropertiesForKeys: nil) {
            for file in files {
                let ext = file.pathExtension.lowercased()
                if animationExtensions.contains(ext) && file != newAssetURL {
                    allAssets.append(file)
                }
            }
        }

        // Shuffle and take up to (maxHomeScreenAssets - 1) to leave room for new asset
        let shuffled = allAssets.shuffled()
        let count = min(shuffled.count, maxHomeScreenAssets - 1)
        homeAssets = Array(shuffled.prefix(count))

        // Add the newly imported asset as the last item
        homeAssets.append(newAssetURL)

        // Set current index to the newly imported item
        currentAssetIndex = homeAssets.count - 1

        // Recreate the entire home view from scratch
        createHomeView(frame: contentContainer.bounds)

        // Show the home view
        if let segmentedControl = window?.contentView?.subviews.first(where: { $0 is NSSegmentedControl }) as? NSSegmentedControl {
            segmentedControl.selectedSegment = 0
            showView(homeView)
        }

        print("Reloaded home screen with \(homeAssets.count) assets, new asset at index \(currentAssetIndex)")
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

extension AppDelegate {
    func downloadWallpaperFromAPI(urlString: String, name: String, type: String) {
        guard let url = URL(string: urlString),
              let assetsFolderURL = assetsFolderURL else { return }

        // Determine destination folder based on type
        let folderName: String
        let fileExtension: String

        switch type.lowercased() {
        case "video", "live":
            folderName = "Videos"
            fileExtension = "mp4"
        case "image":
            folderName = "Images"
            fileExtension = "jpg"
        default:
            folderName = "Images"
            fileExtension = "jpg"
        }

        let destinationFolder = assetsFolderURL.appendingPathComponent(folderName)
        ensureFolderExists(at: destinationFolder)

        // Sanitize filename
        let sanitizedName = name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        let filename = "\(sanitizedName).\(fileExtension)"
        let destinationURL = destinationFolder.appendingPathComponent(filename)

        // Download file
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self,
                  let tempURL = tempURL,
                  error == nil else {
                print("Download failed: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            do {
                // Move file to destination
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                print("Downloaded wallpaper: \(destinationURL.path)")

                // Reload home screen with new asset
                DispatchQueue.main.async {
                    self.reloadHomeScreenWithNewAsset(destinationURL)
                    self.showNotification(message: "Wallpaper downloaded!")
                }
            } catch {
                print("Failed to save wallpaper: \(error.localizedDescription)")
            }
        }
        task.resume()
    }
}
