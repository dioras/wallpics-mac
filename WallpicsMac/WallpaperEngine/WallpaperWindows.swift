import Cocoa
import AVFoundation
import Metal
import MetalKit
import RiveRuntime

protocol WallpaperWindowControl: AnyObject {
    func pause()
    func resume()
    func stop()
}

private func makeDesktopWindow(screen: NSScreen) -> NSWindow {
    let window = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    window.ignoresMouseEvents = true
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    return window
}

// MARK: - GIF

final class GIFWallpaperWindow: NSWindow, WallpaperWindowControl {
    private var imageView: NSImageView?

    init(screen: NSScreen, gifURL: URL) {
        let frame = screen.frame
        super.init(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false
        setupGIF(url: gifURL, frame: frame)
    }

    private func setupGIF(url: URL, frame: NSRect) {
        guard let image = NSImage(contentsOf: url) else { return }
        let imageView = NSImageView(frame: frame)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.image = image

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(imageView)

        self.imageView = imageView
        self.contentView = container
    }

    func pause() { imageView?.animates = false }
    func resume() { imageView?.animates = true }
    func stop() { imageView?.image = nil; imageView = nil }
}

// MARK: - Video

final class VideoWallpaperWindow: NSWindow, WallpaperWindowControl {
    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?

    init(screen: NSScreen, videoURL: URL) {
        let frame = screen.frame
        super.init(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false
        setupPlayer(url: videoURL, frame: frame)
    }

    private func setupPlayer(url: URL, frame: NSRect) {
        let layer = AVPlayerLayer()
        layer.frame = frame
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let player = AVPlayer(url: url)
        player.isMuted = true
        layer.player = player
        self.player = player

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.layer?.addSublayer(layer)
        self.contentView = container

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

    func pause() { player?.pause() }
    func resume() { player?.play() }

    func stop() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
    }
}

// MARK: - Shader

final class ShaderWallpaperWindow: NSWindow, WallpaperWindowControl {
    private var renderer: ShaderRenderer?

    init(screen: NSScreen, shaderURL: URL) {
        let frame = screen.frame
        super.init(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false
        setup(url: shaderURL, frame: frame)
    }

    private func setup(url: URL, frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let view = MTKView(frame: frame, device: device)
        view.autoresizingMask = [.width, .height]
        let renderer = ShaderRenderer(device: device, shaderSource: source)
        self.renderer = renderer
        view.delegate = renderer
        self.contentView = view
    }

    func pause() { renderer?.pause() }
    func resume() { renderer?.resume() }
    func stop() { renderer = nil }
}

// MARK: - Animation (Rive)

final class AnimationWallpaperWindow: NSWindow, WallpaperWindowControl {
    private var viewModel: RiveViewModel?

    init(screen: NSScreen, animationURL: URL) {
        let frame = screen.frame
        super.init(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isReleasedWhenClosed = false
        setup(url: animationURL, frame: frame)
    }

    private func setup(url: URL, frame: NSRect) {
        let vm = RiveViewModel(webURL: url.absoluteString, fit: .fill, alignment: .center, loadCdn: false)
        viewModel = vm
        let view = vm.createRiveView()
        view.frame = frame
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        contentView = view
        vm.play(loop: RiveLoop.loop)
        muteWhenReady(vm)
    }

    private func muteWhenReady(_ vm: RiveViewModel) {
        Task { @MainActor in
            for _ in 0..<10 {
                if vm.riveModel?.volume != nil {
                    vm.riveModel?.volume = 0
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func pause() { viewModel?.pause() }
    func resume() { viewModel?.play(loop: RiveLoop.loop) }
    func stop() { viewModel?.stop(); viewModel = nil }
}

// MARK: - Shader renderer

final class ShaderRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var startTime = Date()
    private var isPaused = false
    private var pausedElapsed: Float = 0

    private struct Uniforms {
        var iResolution: SIMD2<Float>
        var iTime: Float
        var padding: Float
    }

    init(device: MTLDevice, shaderSource: String) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        super.init()
        compile(shaderSource: shaderSource)
    }

    private func compile(shaderSource: String) {
        let vertexShader = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 uv; };
        struct Uniforms { float2 iResolution; float iTime; };
        vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
            VertexOut out;
            float2 positions[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
            float2 uvs[6] = { float2(0,1), float2(1,1), float2(0,0), float2(0,0), float2(1,1), float2(1,0) };
            out.position = float4(positions[vertexID], 0, 1);
            out.uv = uvs[vertexID];
            return out;
        }
        """
        do {
            let library = try device.makeLibrary(source: vertexShader + "\n" + shaderSource, options: nil)
            guard let vfn = library.makeFunction(name: "vertexShader"),
                  let ffn = library.makeFunction(name: "fragmentShader") else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Log.engine.error("Shader compile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pause() {
        pausedElapsed = Float(Date().timeIntervalSince(startTime).truncatingRemainder(dividingBy: 300))
        isPaused = true
    }

    func resume() {
        isPaused = false
        startTime = Date().addingTimeInterval(-Double(pausedElapsed))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !isPaused,
              let pipeline = pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let elapsed = Float(Date().timeIntervalSince(startTime).truncatingRemainder(dividingBy: 300))
        var uniforms = Uniforms(
            iResolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            iTime: elapsed,
            padding: 0
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension NSWindow {
    static func makeDesktopLevel(for screen: NSScreen) -> NSWindow { makeDesktopWindow(screen: screen) }
}

// MARK: - Live watermark overlay

/// A small bottom-left badge pinned over a live (video/gif/shader/Rive) wallpaper window for
/// free users — the live-content equivalent of the baked-in image watermark. A faint chip
/// keeps it readable over any moving content.
@MainActor
enum WatermarkOverlay {
    static func attach(to window: NSWindow, appIcon: NSImage?) {
        guard let content = window.contentView else { return }

        let margin: CGFloat = 28
        let iconSize: CGFloat = 46
        let width: CGFloat = 330
        let height: CGFloat = iconSize + 20

        let badge = NSView(frame: NSRect(x: margin, y: margin, width: width, height: height))
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        badge.layer?.cornerRadius = 12
        badge.layer?.cornerCurve = .continuous
        // Stay pinned to the bottom-left as the wallpaper window resizes.
        badge.autoresizingMask = [.maxXMargin, .maxYMargin]

        let pad: CGFloat = 10
        if let appIcon {
            let iconView = NSImageView(frame: NSRect(x: pad, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            iconView.image = appIcon
            iconView.alphaValue = 0.5
            iconView.imageScaling = .scaleProportionallyUpOrDown
            badge.addSubview(iconView)
        }

        let textX = pad + iconSize + 10
        let title = NSTextField(labelWithString: "WallPics")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = NSColor.white.withAlphaComponent(0.95)
        title.frame = NSRect(x: textX, y: height / 2, width: width - textX - pad, height: 20)
        badge.addSubview(title)

        let subtitle = NSTextField(labelWithString: String(localized: "Unlock Pro to remove this watermark"))
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.8)
        subtitle.frame = NSRect(x: textX, y: height / 2 - 18, width: width - textX - pad, height: 16)
        badge.addSubview(subtitle)

        content.addSubview(badge)
    }
}
