import Foundation

/// A browse category from `api/category-list`. Categories form a two-level tree: roots like
/// "Cars 🚗" carry `children` subcategories ("Audi", "BMW", …). Either level's `slug` can be
/// passed to the wallpaper endpoints as `categorySlug`.
struct WallpaperCategory: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let slug: String
    let children: [WallpaperCategory]
    let wallpapersCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, children
        case wallpapersCount = "wallpapers_count"
    }

    init(id: Int, name: String, slug: String, children: [WallpaperCategory] = [], wallpapersCount: Int? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.children = children
        self.wallpapersCount = wallpapersCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decode(String.self, forKey: .slug)
        children = (try? c.decodeIfPresent([WallpaperCategory].self, forKey: .children)) ?? []
        wallpapersCount = try? c.decodeIfPresent(Int.self, forKey: .wallpapersCount)
    }
}

struct CategoryListResponse: Decodable {
    let data: [WallpaperCategory]
}

extension WallpaperCategory {
    var cleanName: String {
        name.unicodeScalars
            .filter { !($0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
    }
}
