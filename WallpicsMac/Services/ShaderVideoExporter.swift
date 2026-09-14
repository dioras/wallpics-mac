import AVFoundation
import CoreVideo
import Foundation
import Metal

enum ShaderVideoExporter {
    enum Failure: LocalizedError {
        case setup(String)
        case encode(String)

        var errorDescription: String? {
            String(localized: "Couldn't prepare the lock screen clip.")
        }

        var detail: String {
            switch self {
            case .setup(let d), .encode(let d): return d
            }
        }
    }

    static let maxWidth = 3840

    static func export(shaderSource: String,
                       pixelSize: CGSize,
                       duration: Double = LockScreenAerial.minimumClipSeconds,
                       fps: Int32 = 30,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let (width, height) = outputSize(for: pixelSize)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { throw Failure.setup("no Metal device") }
        let pipeline = try makePipeline(device: device, shaderSource: shaderSource)

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let textureCache else { throw Failure.setup("no texture cache") }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let bitrate = Int(Double(width * height) * Double(fps) * 0.07)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure.setup("writer rejected input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.encode(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            guard let pool = adaptor.pixelBufferPool else { throw Failure.setup("no pixel buffer pool") }
            let frameCount = Int(duration * Double(fps))
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                var cvTexture: CVMetalTexture?
                guard let pixelBuffer,
                      CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                                width, height, 0, &cvTexture) == kCVReturnSuccess,
                      let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
                else { throw Failure.encode("pixel buffer texture failed at frame \(frame)") }

                let time = Float(Double(frame) / Double(fps))
                try await render(time: time, into: texture, width: width, height: height, pipeline: pipeline, queue: queue)

                let presentation = CMTime(value: CMTimeValue(frame), timescale: fps)
                guard adaptor.append(pixelBuffer, withPresentationTime: presentation) else {
                    throw Failure.encode(writer.error?.localizedDescription ?? "append failed at frame \(frame)")
                }
                if frame % Int(fps) == 0 {
                    progress?(Double(frame) / Double(frameCount))
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw Failure.encode(writer.error?.localizedDescription ?? "finishWriting status \(writer.status.rawValue)")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: out)
            if !(error is CancellationError) {
                Log.engine.error("Shader clip export failed: \(error.localizedDescription, privacy: .public) \((error as? Failure)?.detail ?? "", privacy: .public)")
            }
            throw error
        }
        progress?(1)
        return out
    }

    private static func render(time: Float, into texture: MTLTexture, width: Int, height: Int,
                               pipeline: MTLRenderPipelineState, queue: MTLCommandQueue) async throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        var uniforms = ShaderRenderer.Uniforms(
            iResolution: SIMD2<Float>(Float(width), Float(height)), iTime: time, padding: 0
        )
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { throw Failure.encode("no command buffer") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderRenderer.Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
    }

    private static func makePipeline(device: MTLDevice, shaderSource: String) throws -> MTLRenderPipelineState {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderRenderer.vertexPreamble + "\n" + shaderSource, options: nil)
        } catch {
            throw Failure.setup("shader compile: \(error.localizedDescription)")
        }
        guard let vertexFn = library.makeFunction(name: "vertexShader"),
              let fragmentFn = library.makeFunction(name: "fragmentShader")
        else { throw Failure.setup("shader is missing vertexShader/fragmentShader") }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw Failure.setup("pipeline: \(error.localizedDescription)")
        }
    }

    private static func outputSize(for pixelSize: CGSize) -> (Int, Int) {
        var width = max(2, Int(pixelSize.width))
        var height = max(2, Int(pixelSize.height))
        if width > maxWidth {
            height = Int(Double(height) * Double(maxWidth) / Double(width))
            width = maxWidth
        }
        return (width & ~1, max(2, height & ~1))
    }
}
