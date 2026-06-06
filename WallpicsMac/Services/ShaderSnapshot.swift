import Metal
import CoreGraphics
import AppKit

/// Renders a single full-resolution frame of an `.msl` shader off-screen, so we have a crisp
/// static still to use as the desktop image. macOS shows the desktop *picture* (not the app's
/// live wallpaper window) on the lock/login screen and whenever the app isn't running — without
/// this, a shader wallpaper would fall back to its tiny thumbnail and look pixelated there.
enum ShaderSnapshot {
    /// Render `shaderSource` at `pixelSize` and return the frame as a CGImage. Uses the exact same
    /// vertex preamble + uniforms as the live `ShaderRenderer`, so the still matches the animation.
    static func render(shaderSource: String, pixelSize: CGSize, time: Float = 2.0) -> CGImage? {
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderRenderer.vertexPreamble + "\n" + shaderSource, options: nil),
              let vertexFn = library.makeFunction(name: "vertexShader"),
              let fragmentFn = library.makeFunction(name: "fragmentShader")
        else { return nil }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc) else { return nil }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

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
        else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderRenderer.Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return cgImage(from: texture, width: width, height: height)
    }

    private static func cgImage(from texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&data, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        // bgra8Unorm -> little-endian 32-bit with premultiplied-first alpha.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        return context.makeImage()
    }
}
