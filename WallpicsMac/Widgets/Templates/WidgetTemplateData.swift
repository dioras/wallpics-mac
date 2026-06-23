import Foundation

enum WidgetDeviceInfo {
    static let chipName: String = {
        let raw = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        if let range = raw.range(of: "Apple ") { return String(raw[range.upperBound...]) }
        return raw
    }()

    static let modelName: String = {
        sysctlString("hw.model") ?? "Mac"
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct BibleVerse: Equatable { let text: String; let reference: String }

enum WidgetBibleProvider {
    private static let fallback = BibleVerse(
        text: "For God so loved the world, that he gave his only Son.",
        reference: "John 3:16"
    )
    private static let cache = NSCache<NSString, VerseBox>()
    private final class VerseBox { let verses: [BibleVerse]; init(_ v: [BibleVerse]) { verses = v } }

    static func today(in dir: URL?) -> BibleVerse {
        guard let verses = loadVerses(in: dir), !verses.isEmpty else { return fallback }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return verses[(day - 1) % verses.count]
    }

    private static func loadVerses(in dir: URL?) -> [BibleVerse]? {
        guard let dir else { return nil }
        let url = dir.appendingPathComponent("verses_web.json")
        if let box = cache.object(forKey: url.path as NSString) { return box.verses }
        guard let data = try? Data(contentsOf: url) else { return nil }
        func parse(_ arr: [[String: Any]]) -> [BibleVerse] {
            arr.compactMap { item in
                let text = (item["text"] ?? item["verse"] ?? item["content"]) as? String
                let ref = (item["reference"] ?? item["ref"]) as? String
                guard let text, !text.isEmpty else { return nil }
                return BibleVerse(text: text, reference: ref ?? "")
            }
        }
        var parsed: [BibleVerse] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            parsed = parse(arr)
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["verses"] as? [[String: Any]] {
            parsed = parse(arr)
        }
        guard !parsed.isEmpty else { return nil }
        cache.setObject(VerseBox(parsed), forKey: url.path as NSString)
        return parsed
    }
}

enum WidgetTemplateText {
    static func resolve(_ content: TemplateContent, replacements: [String: String], bundleDir: URL?) -> String {
        if let key = content.replaceKey, !key.isEmpty {
            if let explicit = replacements[key] { return explicit }
            switch key {
            case "cpuChip": return WidgetDeviceInfo.chipName
            case "deviceModel": return WidgetDeviceInfo.modelName
            case "bibleVerse": return WidgetBibleProvider.today(in: bundleDir).text
            case "bibleReference": return WidgetBibleProvider.today(in: bundleDir).reference
            default: break
            }
        }
        return content.text ?? ""
    }
}
