import Foundation
import CoreGraphics

struct FlexibleNumber: Decodable, Equatable {
    let value: CGFloat
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = CGFloat(d) }
        else if let s = try? c.decode(String.self), let d = Double(s.trimmingCharacters(in: .whitespaces)) { value = CGFloat(d) }
        else { value = 0 }
    }
}

struct TemplatePoint: Decodable, Equatable {
    let x: CGFloat
    let y: CGFloat
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? c.decode(FlexibleNumber.self, forKey: .x))?.value ?? 0
        y = (try? c.decode(FlexibleNumber.self, forKey: .y))?.value ?? 0
    }
    enum CodingKeys: String, CodingKey { case x, y }
}

struct TemplateContent: Decodable, Equatable {
    var text: String?
    var textColor: String?
    var fontSize: FlexibleNumber?
    var lineSpacing: FlexibleNumber?
    var lineLimit: FlexibleNumber?
    var textAlignment: String?
    var verticalAlignment: String?
    var font: String?
    var replaceKey: String?
    var frequence: String?
    var backgrounds: String?
    var mask: String?
    var rotationAngle: FlexibleNumber?
    var narrowWindow: Bool?
    var category: String?
    var subCategory: String?
    var oneLineCount: FlexibleNumber?
    var itemOverlay: String?
    var itemSize: String?
    var imageOffset: String?
    var imageSize: String?

    var framePaths: [String] {
        guard let backgrounds, !backgrounds.isEmpty else { return [] }
        return backgrounds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var isAnimated: Bool {
        let paths = framePaths
        if paths.count == 1, paths[0].lowercased().hasSuffix(".webp") { return true }
        return paths.count > 1
    }
}

struct TemplateComponent: Decodable, Equatable {
    let type: String
    let content: TemplateContent
    let size: TemplatePoint?
    let offset: TemplatePoint?
    let alignment: String?
}

struct TemplateDataContent: Decodable, Equatable {
    var maxCount: FlexibleNumber?
    var images: String?
    var pictureFrameImages: String?
    var imageSize: String?
    var imagePaths: [String] { csv(images) }
    var framePaths: [String] { csv(pictureFrameImages) }
    private func csv(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct TemplateData: Decodable, Equatable {
    var type: String?
    var content: TemplateDataContent?
}

struct WidgetTemplateConfig: Decodable, Equatable {
    var version: Int?
    var sizeType: String?
    var widgetType: String?
    var name: String?
    var thumbnail: String?
    var background: String?
    var asset: String?
    var components: [TemplateComponent]?
    var data: TemplateData?

    enum CodingKeys: String, CodingKey {
        case version, sizeType, widgetType, name, thumbnail, background, asset, components, data
    }

    var canvasSize: CGSize {
        switch (sizeType ?? "").lowercased() {
        case "rectangle": return CGSize(width: 160, height: 72)
        case "circular":  return CGSize(width: 72, height: 72)
        case "square":    return CGSize(width: 160, height: 160)
        case "large":     return CGSize(width: 338, height: 354)
        case "medium":    return CGSize(width: 338, height: 158)
        case "small":     return CGSize(width: 158, height: 158)
        default:          return CGSize(width: 160, height: 72)
        }
    }

    static func parseSize(_ s: String?) -> CGSize? {
        guard let parts = s?.split(separator: ","), parts.count == 2,
              let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func parsePoint(_ s: String?) -> CGPoint? {
        guard let parts = s?.split(separator: ","), parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

enum WidgetTemplateConfigLoader {
    private static let cache = NSCache<NSString, CacheBox>()
    private final class CacheBox { let config: WidgetTemplateConfig?; init(_ c: WidgetTemplateConfig?) { config = c } }

    static func load(slug: String, family: String) -> (config: WidgetTemplateConfig, dir: URL)? {
        let base = WidgetPaths.templateDirectory(slug: slug)
        let candidates = [base.appendingPathComponent(family), base, base.appendingPathComponent("small"),
                          base.appendingPathComponent("medium"), base.appendingPathComponent("large")]
        for dir in candidates {
            let url = dir.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let key = url.path as NSString
            if let box = cache.object(forKey: key) {
                if let cfg = box.config { return (cfg, dir) }
                continue
            }
            let decoded = try? JSONDecoder().decode(WidgetTemplateConfig.self, from: Data(contentsOf: url))
            cache.setObject(CacheBox(decoded), forKey: key)
            if let cfg = decoded { return (cfg, dir) }
        }
        return nil
    }
}
