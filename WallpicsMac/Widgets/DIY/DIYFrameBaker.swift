import SwiftUI
import AppKit

struct DIYTemplateConfig: Decodable, Equatable {
    let frameCount: Int
    let playbackDuration: Double?
    let slotSize: SizeWH
    let photoFrame: RectXYWH
    let handOffset: PointXY?

    struct SizeWH: Decodable, Equatable { let width: CGFloat; let height: CGFloat }
    struct RectXYWH: Decodable, Equatable { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }
    struct PointXY: Decodable, Equatable { let x: CGFloat; let y: CGFloat }

    var resolvedHandOffset: CGSize { CGSize(width: handOffset?.x ?? 0, height: handOffset?.y ?? 0) }
}

enum DIYTemplateConfigLoader {
    static func load(slug: String, family: WidgetFamily) -> (config: DIYTemplateConfig, dir: URL)? {
        let folder: String
        switch family { case .small: folder = "small"; case .medium: folder = "medium"; case .large: folder = "large" }
        let base = WidgetPaths.templateDirectory(slug: slug)
        let candidates = [base.appendingPathComponent(folder), base.appendingPathComponent("small"), base]
        for dir in candidates {
            let url = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: url),
                  let cfg = try? JSONDecoder().decode(DIYTemplateConfig.self, from: data),
                  cfg.frameCount > 0 else { continue }
            return (cfg, dir)
        }
        return nil
    }
}

enum DIYSqueeze {
    private static let keyframes: [(t: Double, x: CGFloat, y: CGFloat)] = [
        (0.000, 1.00, 1.00),
        (0.070, 1.04, 0.86),
        (0.141, 1.10, 0.66),
        (0.211, 1.03, 0.86),
        (0.246, 1.00, 1.00),
        (0.316, 1.04, 0.86),
        (0.387, 1.10, 0.66),
        (0.457, 1.03, 0.86),
        (0.492, 1.00, 1.00),
        (0.562, 1.04, 0.86),
        (0.633, 1.10, 0.66),
        (0.703, 1.03, 0.86),
        (0.738, 1.00, 1.00),
        (0.808, 1.04, 0.86),
        (0.879, 1.10, 0.66),
        (0.949, 1.03, 0.86),
        (1.000, 1.00, 1.00)
    ]

    static func scale(at progress: Double) -> (CGFloat, CGFloat) {
        let p = min(max(progress, 0), 1)
        guard let first = keyframes.first else { return (1, 1) }
        if p <= first.t { return (first.x, first.y) }
        for i in 1..<keyframes.count {
            let a = keyframes[i - 1], b = keyframes[i]
            if p <= b.t {
                let span = b.t - a.t
                let f = span > 0 ? CGFloat((p - a.t) / span) : 0
                return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
            }
        }
        return (1, 1)
    }
}

@MainActor
enum DIYFrameBaker {
    struct Output { let frames: [String]; let cover: String? }

    static func bake(slug: String, family: WidgetFamily, userPhoto: NSImage?, into id: UUID) -> Output {
        guard let (cfg, dir) = DIYTemplateConfigLoader.load(slug: slug, family: family) else {
            return Output(frames: [], cover: nil)
        }
        let hands: [NSImage] = (1...cfg.frameCount).compactMap {
            WidgetImage.load(at: dir.appendingPathComponent("frame\($0).png").path, maxPixelSize: 1024)
        }
        guard hands.count == cfg.frameCount else { return Output(frames: [], cover: nil) }

        var rels: [String] = []
        for i in 0..<cfg.frameCount {
            let progress = cfg.frameCount > 1 ? Double(i) / Double(cfg.frameCount - 1) : 0
            let (xs, ys) = DIYSqueeze.scale(at: progress)
            let view = DIYBakedFrame(config: cfg, photo: userPhoto, hand: hands[i], xScale: xs, yScale: ys)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let name = WidgetStore.shared.writeImage(image, named: String(format: "diy_%03d.jpg", i), into: id) else { continue }
            rels.append(name)
        }
        return Output(frames: rels, cover: rels.first)
    }
}

private struct DIYBakedFrame: View {
    let config: DIYTemplateConfig
    let photo: NSImage?
    let hand: NSImage
    let xScale: CGFloat
    let yScale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
                .frame(width: config.slotSize.width, height: config.slotSize.height)
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: config.photoFrame.width, height: config.photoFrame.height)
                    .clipped()
                    .scaleEffect(x: xScale, y: yScale, anchor: .center)
                    .position(x: config.photoFrame.x + config.photoFrame.width / 2,
                              y: config.photoFrame.y + config.photoFrame.height / 2)
            }
            Image(nsImage: hand)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: config.slotSize.width, height: config.slotSize.height)
                .clipped()
                .offset(x: config.resolvedHandOffset.width, y: config.resolvedHandOffset.height)
        }
        .frame(width: config.slotSize.width, height: config.slotSize.height)
        .clipped()
    }
}
