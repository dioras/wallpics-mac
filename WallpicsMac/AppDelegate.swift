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

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true

        // Show play button
        if playButtonView == nil {
            // Create play button image once
            if HoverScaleView.playButtonImage == nil {
                HoverScaleView.playButtonImage = HoverScaleView.createPlayButtonImage(size: 80)
            }

            let buttonSize: CGFloat = 80
            let buttonFrame = NSRect(
                x: (bounds.width - buttonSize) / 2,
                y: (bounds.height - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            )
            let imageView = NSImageView(frame: buttonFrame)
            imageView.image = HoverScaleView.playButtonImage
            imageView.alphaValue = 0
            imageView.wantsLayer = true

            // Add click gesture
            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(playButtonClicked(_:)))
            imageView.addGestureRecognizer(clickGesture)

            addSubview(imageView)
            playButtonView = imageView
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

            // Fade in play button
            self.playButtonView?.animator().alphaValue = 1.0
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

    @objc func playButtonClicked(_ sender: NSClickGestureRecognizer) {
        print("Play button clicked!")
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

    // Browser view data
    var wallpaperData: [[String: Any]] = []
    var filteredWallpaperData: [[String: Any]] = []
    var searchField: NSSearchField?
    var globalTagsContainer: NSView?
    var currentPage: Int = 1
    var isLoadingWallpapers: Bool = false
    var browserScrollView: NSScrollView?
    var browserGridContainer: NSView?
    var guestId: String?
    var useMacOSEndpoint: Bool = true

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

        // Create notification label (invisible by default)
        let labelView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))

        let textLayer = CATextLayer()
        textLayer.frame = labelView.bounds
        textLayer.string = ""
        textLayer.fontSize = 32
        textLayer.font = NSFont.boldSystemFont(ofSize: 32)
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Add stroke (outline)
        textLayer.shadowColor = NSColor.black.cgColor
        textLayer.shadowOffset = CGSize.zero
        textLayer.shadowOpacity = 1.0
        textLayer.shadowRadius = 3.0

        labelView.wantsLayer = true
        labelView.layer?.addSublayer(textLayer)

        // Position in center
        labelView.frame.origin = NSPoint(
            x: (frame.width - 400) / 2,
            y: (frame.height - 100) / 2
        )
        labelView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        labelView.alphaValue = 0

        notificationLabel = labelView
        mainView.addSubview(labelView, positioned: .above, relativeTo: contentContainer)

        // Add segmented control background and control ABOVE everything (added last to be on top)
        if let segmentedControl = segmentedControl {
            segmentedControl.wantsLayer = true

            // Create a background container for the segmented control
            let backgroundPadding: CGFloat = 4
            let backgroundView = NSView(frame: NSRect(
                x: segmentedControlX - backgroundPadding,
                y: segmentedControlY - backgroundPadding / 2,
                width: segmentedControlWidth + (backgroundPadding * 2),
                height: segmentedControlHeight + backgroundPadding
            ))
            backgroundView.wantsLayer = true
            backgroundView.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.8).cgColor
            backgroundView.layer?.cornerRadius = 8
            backgroundView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

            mainView.addSubview(backgroundView, positioned: .above, relativeTo: nil)
            mainView.addSubview(segmentedControl, positioned: .above, relativeTo: backgroundView)
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

    func createBrowserView(frame: NSRect) {
        browserView = NSView(frame: frame)
        browserView?.wantsLayer = true
        browserView?.autoresizingMask = [.width, .height]

        guard let browserView = browserView else { return }

        // Create search field at top with padding
        let searchFieldHeight: CGFloat = 30
        let searchFieldPadding: CGFloat = 20
        let searchFieldTopOffset: CGFloat = 10 + searchFieldHeight
        let search = NSSearchField(frame: NSRect(
            x: searchFieldPadding,
            y: frame.height - searchFieldHeight - searchFieldTopOffset,
            width: frame.width - (searchFieldPadding * 2),
            height: searchFieldHeight
        ))
        search.placeholderString = "Search wallpapers..."
        search.autoresizingMask = [.width, .minYMargin]
        search.target = self
        search.action = #selector(searchFieldChanged(_:))
        searchField = search
        browserView.addSubview(search)

        // Create global tags container below search field (initially empty, will resize when tags load)
        let tagsContainerHeight: CGFloat = 0
        let tagsContainerY = frame.height - searchFieldHeight - searchFieldTopOffset - 10 - tagsContainerHeight
        let tagsContainer = NSView(frame: NSRect(
            x: searchFieldPadding,
            y: tagsContainerY,
            width: frame.width - (searchFieldPadding * 2),
            height: tagsContainerHeight
        ))
        tagsContainer.wantsLayer = true
        tagsContainer.autoresizingMask = []
        globalTagsContainer = tagsContainer
        browserView.addSubview(tagsContainer)

        // Create scroll view below tags
        let scrollViewY: CGFloat = 0
        let scrollViewHeight = tagsContainerY - 10
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
        let itemHeight = itemWidth * 0.75 // 0.75 aspect ratio

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

    func createWallpaperThumbnail(wallpaper: [String: Any], frame: NSRect) -> NSView {
        let itemView = HoverScaleView(frame: frame)
        itemView.wantsLayer = true
        itemView.layer?.backgroundColor = NSColor.darkGray.cgColor
        itemView.layer?.cornerRadius = 8
        // Default anchor point is already (0.5, 0.5) = center

        // Create clipping container with top-only rounded corners
        let clipContainer = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        clipContainer.wantsLayer = true
        clipContainer.layer?.cornerRadius = 8
        clipContainer.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] // Top corners only
        clipContainer.layer?.masksToBounds = true
        itemView.addSubview(clipContainer)

        // Load thumbnail image asynchronously
        if let thumbnailURLString = wallpaper["thumbnail"] as? String,
           let thumbnailURL = URL(string: thumbnailURLString) {
            URLSession.shared.dataTask(with: thumbnailURL) { data, _, error in
                guard let data = data, error == nil, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
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

        // Add black semi-transparent overlay at bottom 20%
        let overlayHeight = frame.height * 0.2
        let overlayView = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: overlayHeight))
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor // 30% transparency = 70% opacity
        itemView.addSubview(overlayView)

        // Add white text label with wallpaper name
        if let name = wallpaper["name"] as? String {
            let label = NSTextField(labelWithString: name)
            label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            label.textColor = .white
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 10, y: overlayHeight - 22, width: frame.width - 20, height: 18)
            overlayView.addSubview(label)
        }

        // Add "Set" button aligned to the right
        let buttonHeight: CGFloat = 20
        let font = NSFont.systemFont(ofSize: 11)
        let setButtonText = "Set"
        let setButtonTextSize = (setButtonText as NSString).size(withAttributes: [.font: font])
        let setButtonWidth = setButtonTextSize.width + 16

        let setButton = NSView(frame: NSRect(x: frame.width - setButtonWidth - 10, y: 5, width: setButtonWidth, height: buttonHeight))
        setButton.wantsLayer = true
        setButton.layer?.backgroundColor = NSColor(red: 211/255.0, green: 45/255.0, blue: 74/255.0, alpha: 1.0).cgColor
        setButton.layer?.cornerRadius = buttonHeight * 0.5

        let setLabel = NSTextField(labelWithString: setButtonText)
        setLabel.font = font
        setLabel.textColor = .white
        setLabel.alignment = .center
        setLabel.frame = NSRect(x: 0, y: -2, width: setButtonWidth, height: buttonHeight)
        setButton.addSubview(setLabel)

        let setClickGesture = NSClickGestureRecognizer(target: self, action: #selector(setButtonClicked(_:)))
        setButton.addGestureRecognizer(setClickGesture)
        overlayView.addSubview(setButton)

        // Add second line for tags as custom views
        if let tags = wallpaper["tags"] as? [[String: Any]] {
            let tagNames = tags.compactMap { $0["name"] as? String }
            if !tagNames.isEmpty {
                // Take only first 3 tags
                let displayTags = Array(tagNames.prefix(3))

                var xOffset: CGFloat = 10
                let buttonSpacing: CGFloat = 6
                let maxXOffset = frame.width - setButtonWidth - 20 // Leave space for Set button

                for tagName in displayTags {
                    // Calculate button width based on text
                    let textSize = (tagName as NSString).size(withAttributes: [.font: font])
                    let buttonWidth = textSize.width + 16 // Add padding

                    // Stop if we would overlap with Set button
                    if xOffset + buttonWidth > maxXOffset {
                        break
                    }

                    // Create custom view for tag
                    let tagView = NSView(frame: NSRect(x: xOffset, y: 5, width: buttonWidth, height: buttonHeight))
                    tagView.wantsLayer = true
                    tagView.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
                    tagView.layer?.cornerRadius = buttonHeight * 0.5

                    // Add text label
                    let label = NSTextField(labelWithString: tagName)
                    label.font = font
                    label.textColor = .white
                    label.alignment = .center
                    label.frame = NSRect(x: 0, y: -2, width: buttonWidth, height: buttonHeight)
                    tagView.addSubview(label)

                    // Add click gesture
                    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(tagButtonClicked(_:)))
                    tagView.addGestureRecognizer(clickGesture)

                    overlayView.addSubview(tagView)

                    xOffset += buttonWidth + buttonSpacing
                }
            }
        }

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
        print("Set button clicked!")
    }

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        filterWallpapers()
    }

    func displayGlobalTags() {
        guard let tagsContainer = globalTagsContainer,
              let browserView = browserView,
              let scrollView = browserScrollView else { return }

        // Clear existing tags
        tagsContainer.subviews.forEach { $0.removeFromSuperview() }

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

        // Add "All" as first tag
        var displayTags = ["All"] + uniqueTags

        // Create tag buttons
        let buttonHeight: CGFloat = 20
        let buttonSpacing: CGFloat = 6
        let font = NSFont.systemFont(ofSize: 11)

        // First pass: calculate required height
        let searchFieldPadding: CGFloat = 20
        let containerWidth = browserView.bounds.width - (searchFieldPadding * 2)
        var xOffset: CGFloat = 0
        var lineCount: CGFloat = 1

        for tagName in displayTags {
            let textSize = (tagName as NSString).size(withAttributes: [.font: font])
            let buttonWidth = textSize.width + 16

            if xOffset + buttonWidth > containerWidth && xOffset > 0 {
                lineCount += 1
                xOffset = 0
            }
            xOffset += buttonWidth + buttonSpacing
        }

        // Calculate actual height needed
        let actualHeight = lineCount * buttonHeight + (lineCount - 1) * buttonSpacing

        // Resize tags container
        let searchFieldHeight: CGFloat = 30
        let searchFieldTopOffset: CGFloat = 10 + searchFieldHeight / 2
        let newTagsY = browserView.bounds.height - searchFieldHeight - searchFieldTopOffset - 10 - actualHeight - (actualHeight * 0.75)
        tagsContainer.frame = NSRect(
            x: searchFieldPadding,
            y: newTagsY,
            width: containerWidth,
            height: actualHeight
        )

        // Update scroll view frame
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: browserView.bounds.width,
            height: newTagsY - 10
        )

        // Second pass: create and layout tags
        xOffset = 0
        var yOffset: CGFloat = actualHeight - buttonHeight

        for tagName in displayTags {
            // Calculate button width
            let textSize = (tagName as NSString).size(withAttributes: [.font: font])
            let buttonWidth = textSize.width + 16

            // Check if we need to wrap to next line
            if xOffset + buttonWidth > containerWidth && xOffset > 0 {
                xOffset = 0
                yOffset -= buttonHeight + buttonSpacing
            }

            // Create tag view
            let tagView = NSView(frame: NSRect(x: xOffset, y: yOffset, width: buttonWidth, height: buttonHeight))
            tagView.wantsLayer = true
            tagView.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
            tagView.layer?.cornerRadius = buttonHeight * 0.5

            // Add text label
            let label = NSTextField(labelWithString: tagName)
            label.font = font
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: -2, width: buttonWidth, height: buttonHeight)
            tagView.addSubview(label)

            // Add click gesture
            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(globalTagClicked(_:)))
            tagView.addGestureRecognizer(clickGesture)

            tagsContainer.addSubview(tagView)

            xOffset += buttonWidth + buttonSpacing
        }
    }

    @objc func globalTagClicked(_ sender: NSClickGestureRecognizer) {
        guard let tagView = sender.view,
              let label = tagView.subviews.first as? NSTextField else { return }

        let tagName = label.stringValue

        if tagName == "All" {
            // Clear search field and filter
            searchField?.stringValue = ""
            filterWallpapers()
        } else {
            // Set search field to tag name and filter
            searchField?.stringValue = tagName
            filterWallpapers()
        }
    }

    func filterWallpapers() {
        let searchText = searchField?.stringValue.lowercased() ?? ""

        // Save old results for comparison
        let oldFilteredData = filteredWallpaperData

        if searchText.isEmpty {
            // No search text - show all wallpapers
            filteredWallpaperData = wallpaperData
        } else {
            // Filter by name and tags
            filteredWallpaperData = wallpaperData.filter { wallpaper in
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
