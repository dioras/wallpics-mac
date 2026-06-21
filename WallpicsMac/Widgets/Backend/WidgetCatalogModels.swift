import Foundation

// Response models for the backend-driven widget catalog, ported from the iOS
// `WidgetCatalogRes.swift`. These are pure Foundation and decode the same JSON the iOS app does:
//   GET /api/widgets
//   GET /api/category-list?modelType=widget

// MARK: - GET /api/widgets

struct WidgetCatalogRes: Codable {
    var status: String?
    var data: [WidgetCatalogItem]?

    enum CodingKeys: String, CodingKey { case status, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        data = try c.decodeIfPresent([WidgetCatalogItem].self, forKey: .data)
    }
}

// MARK: - GET /api/category-list?modelType=widget

struct WidgetCategoryTreeRes: Codable {
    var status: String?
    var data: [WidgetCategoryNode]?

    enum CodingKeys: String, CodingKey { case status, data }
}

struct WidgetCategoryNode: Codable, Hashable, Identifiable {
    var id: Int?
    var name: String?
    var slug: String?
    var position: Int?
    var children: [WidgetCategoryNode]?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, position, children
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id ?? 0) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Widget catalog item

struct WidgetCatalogItem: Codable, Hashable, Identifiable {
    var id: String?
    var slug: String?
    var name: String?
    var supportedFamilies: [String]?
    var thumbnail: String?
    var bundleURL: String?
    var widgetType: String?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, thumbnail
        case supportedFamilies = "supported_families"
        case bundleURL = "bundle_url"
        case widgetType = "widget_type"
    }

    init(id: String? = nil, slug: String? = nil, name: String? = nil,
         supportedFamilies: [String]? = nil, thumbnail: String? = nil,
         bundleURL: String? = nil, widgetType: String? = nil) {
        self.id = id; self.slug = slug; self.name = name
        self.supportedFamilies = supportedFamilies; self.thumbnail = thumbnail
        self.bundleURL = bundleURL; self.widgetType = widgetType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            id = try c.decodeIfPresent(String.self, forKey: .id)
        }
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        bundleURL = try c.decodeIfPresent(String.self, forKey: .bundleURL)
        widgetType = try c.decodeIfPresent(String.self, forKey: .widgetType)

        if let arr = try? c.decodeIfPresent([String].self, forKey: .supportedFamilies) {
            supportedFamilies = arr
        } else if let str = try? c.decodeIfPresent(String.self, forKey: .supportedFamilies) {
            supportedFamilies = str.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            supportedFamilies = nil
        }
    }

    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }
    var bundleDownloadURL: URL? { bundleURL.flatMap(URL.init(string:)) }

    /// Stable, code-safe key (slug preferred, else snake_cased name), normalised the same way the
    /// iOS app does so the catalog item maps onto an in-app editor/renderer.
    var typeKey: String? {
        let raw: String
        if let slug, !slug.isEmpty {
            raw = slug
        } else if let name, !name.isEmpty {
            raw = name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "_")
        } else {
            return nil
        }
        return Self.normalize(raw)
    }

    private static let typeKeyAliases: [String: String] = [
        "polaroid": "polaroid_album",
        "pet_car": "diy_animated__petcar",
        "cpu_fan": "cpu_fan_webp"
    ]

    private static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        if let r = s.range(of: #"-\d+$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        s = s.replacingOccurrences(of: "-", with: "_")
        return typeKeyAliases[s] ?? s
    }

    /// Map a catalog item to the in-app `WidgetKind` it should open. Routing prefers the backend
    /// `widget_type`, then the normalised `typeKey`. Unknown bundled widgets fall back to the
    /// generic template renderer.
    var resolvedKind: WidgetKind {
        let type = (widgetType ?? "").lowercased()
        let key = typeKey ?? ""

        if type == "static" || key == "static" || key.hasPrefix("static") { return .staticImage }
        if type.contains("diy") || key.hasPrefix("diy_animated") { return .diyAnimated }
        if key.hasPrefix("polaroid") || type == "polaroid" { return .polaroid }
        if key.hasPrefix("windows_xp") { return .windowsXP }
        if key.hasPrefix("garage_door") { return .garageDoor }
        if key.hasPrefix("opened_eyes") { return .openedEyes }
        if key.hasPrefix("elevator") { return .elevator }
        if key.hasPrefix("photo") { return .photo }
        return .template
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id ?? "") }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
