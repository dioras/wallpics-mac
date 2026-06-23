import SwiftUI
import ImageIO

struct WidgetTemplateView: View {
    let slug: String
    let family: WidgetFamily
    var userPhotoURL: URL?
    var replacements: [String: String] = [:]
    let fallbackThumbnailURL: URL?

    @State private var config: WidgetTemplateConfig?
    @State private var dir: URL?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let config, let dir {
                renderConfig(config, dir: dir)
            } else if didLoad, let fallbackThumbnailURL {
                ThumbnailView(url: fallbackThumbnailURL, placeholderTint: .black.opacity(0.15))
            } else if didLoad {
                placeholder
            } else {
                Color.black.opacity(0.12)
            }
        }
        .task(id: slug + "|" + familyFolder) {
            let loaded = WidgetTemplateConfigLoader.load(slug: slug, family: familyFolder)
            config = loaded?.config
            dir = loaded?.dir
            didLoad = true
        }
    }

    private var familyFolder: String {
        switch family {
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        }
    }

    @ViewBuilder
    private func renderConfig(_ config: WidgetTemplateConfig, dir: URL) -> some View {
        if let asset = config.asset,
           let image = WidgetImage.load(at: dir.appendingPathComponent(asset).path, maxPixelSize: 1000) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else if let components = config.components, !components.isEmpty {
            GeometryReader { geo in
                let canvas = config.canvasSize
                let scale = geo.size.width / max(canvas.width, 1)
                ZStack(alignment: .topLeading) {
                    background(config, dir: dir)
                    ForEach(components.indices, id: \.self) { i in
                        componentView(components[i], data: config.data, dir: dir, scale: scale)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .aspectRatio(config.canvasSize.width / config.canvasSize.height, contentMode: .fit)
        } else if let fallbackThumbnailURL {
            ThumbnailView(url: fallbackThumbnailURL, placeholderTint: .black.opacity(0.15))
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func background(_ config: WidgetTemplateConfig, dir: URL) -> some View {
        if let bg = config.background, !bg.isEmpty {
            if bg.hasPrefix("#"), let color = Color(hex: bg) {
                color
            } else if let image = WidgetImage.load(at: dir.appendingPathComponent(bg).path, maxPixelSize: 1000) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func componentView(_ component: TemplateComponent, data: TemplateData?, dir: URL, scale: CGFloat) -> some View {
        let w = (component.size?.x ?? 0) * scale
        let h = (component.size?.y ?? 0) * scale
        let ox = (component.offset?.x ?? 0) * scale
        let oy = (component.offset?.y ?? 0) * scale
        Group {
            switch component.type.lowercased() {
            case "text": textComponent(component.content, dir: dir, scale: scale)
            case "images": imagesComponent(component.content, dir: dir)
            case "album": albumComponent(component.content, data: data, dir: dir, scale: scale)
            default: EmptyView()
            }
        }
        .frame(width: w > 0 ? w : nil, height: h > 0 ? h : nil, alignment: frameAlignment(component.content))
        .offset(x: ox, y: oy)
    }

    private func textComponent(_ content: TemplateContent, dir: URL, scale: CGFloat) -> some View {
        let resolved = WidgetTemplateText.resolve(content, replacements: replacements, bundleDir: dir)
        let color = Color(hex: content.textColor ?? "#FFFFFFFF") ?? .white
        let baseSize = content.fontSize.map { $0.value > 0 ? $0.value : 12 } ?? 12
        let fontSize = max(6, baseSize * scale)
        let limit = Int(content.lineLimit?.value ?? 0)
        return Text(resolved)
            .font(font(named: content.font, size: fontSize))
            .foregroundStyle(color)
            .lineLimit(limit > 0 ? limit : nil)
            .lineSpacing((content.lineSpacing?.value ?? 0) * scale)
            .multilineTextAlignment(textAlignment(content.textAlignment))
            .minimumScaleFactor(0.5)
    }

    @ViewBuilder
    private func imagesComponent(_ content: TemplateContent, dir: URL) -> some View {
        let rotation = Double(content.rotationAngle?.value ?? 0)
        if content.isAnimated {
            AnimatedTemplateImage(dir: dir, content: content).rotationEffect(.degrees(rotation))
        } else if let name = content.framePaths.first ?? content.backgrounds,
                  let image = WidgetImage.load(at: dir.appendingPathComponent(name).path, maxPixelSize: 800) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(rotation))
        } else if let userPhotoURL, let image = WidgetImage.load(at: userPhotoURL, maxPixelSize: 800) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).clipped()
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func albumComponent(_ content: TemplateContent, data: TemplateData?, dir: URL, scale: CGFloat) -> some View {
        let images = albumImages(data: data, dir: dir)
        let itemSize = WidgetTemplateConfig.parseSize(content.itemSize).map { CGSize(width: $0.width * scale, height: $0.height * scale) }
        let cardW = itemSize?.width ?? 90
        let cardH = itemSize?.height ?? 90
        let overlay = content.itemOverlay.flatMap { WidgetImage.load(at: dir.appendingPathComponent($0).path, maxPixelSize: 400) }
        if images.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4 * scale) {
                ForEach(images.prefix(max(1, Int(content.oneLineCount?.value ?? 3))).indices, id: \.self) { i in
                    ZStack {
                        Image(nsImage: images[i]).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: cardW * 0.86, height: cardH * 0.70)
                            .clipped()
                        if let overlay {
                            Image(nsImage: overlay).resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width: cardW, height: cardH)
                }
            }
        }
    }

    private func albumImages(data: TemplateData?, dir: URL) -> [NSImage] {
        if let userPhotoURL, let image = WidgetImage.load(at: userPhotoURL, maxPixelSize: 500) { return [image] }
        let names = data?.content?.imagePaths ?? []
        return names.compactMap { WidgetImage.load(at: dir.appendingPathComponent($0).path, maxPixelSize: 500) }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "rectangle.stack.badge.play").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func font(named name: String?, size: CGFloat) -> Font {
        if let name, !name.isEmpty { return .custom(name, size: size) }
        return .system(size: size)
    }

    private func textAlignment(_ value: String?) -> TextAlignment {
        switch (value ?? "leading").lowercased() {
        case "center": return .center
        case "trailing", "right": return .trailing
        default: return .leading
        }
    }

    private func frameAlignment(_ content: TemplateContent) -> Alignment {
        let h: HorizontalAlignment
        switch (content.textAlignment ?? "leading").lowercased() {
        case "center": h = .center
        case "trailing", "right": h = .trailing
        default: h = .leading
        }
        let v: VerticalAlignment
        switch (content.verticalAlignment ?? "top").lowercased() {
        case "center": v = .center
        case "bottom": v = .bottom
        default: v = .top
        }
        return Alignment(horizontal: h, vertical: v)
    }
}

private struct AnimatedTemplateImage: View {
    let dir: URL
    let content: TemplateContent
    @State private var frames: [NSImage] = []
    @State private var index = 0

    var body: some View {
        Group {
            if frames.isEmpty {
                Color.clear
            } else {
                Image(nsImage: frames[min(index, frames.count - 1)])
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        }
        .task(id: dir.path + (content.backgrounds ?? "")) { await load() }
        .task(id: frames.count) {
            guard frames.count > 1 else { return }
            let per = content.narrowWindow == true ? max(0.08, 1.0 / Double(frames.count)) : 0.9
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(per * 1_000_000_000))
                guard !Task.isCancelled, !frames.isEmpty else { continue }
                index = (index + 1) % frames.count
            }
        }
    }

    private func load() async {
        let paths = content.framePaths
        let base = dir
        let decoded = await Task.detached(priority: .utility) { () -> [NSImage] in
            if paths.count == 1, paths[0].lowercased().hasSuffix(".webp") {
                return Self.decodeAnimated(base.appendingPathComponent(paths[0]))
            }
            return paths.compactMap { WidgetImage.load(at: base.appendingPathComponent($0).path, maxPixelSize: 800) }
        }.value
        guard !Task.isCancelled else { return }
        frames = decoded
        index = 0
    }

    nonisolated private static func decodeAnimated(_ url: URL) -> [NSImage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return [] }
        var result: [NSImage] = []
        for i in 0..<count {
            if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                result.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        return result
    }
}
