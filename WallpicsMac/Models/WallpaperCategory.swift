import Foundation

/// A browse category from `api/category-list`. Categories form a two-level tree: roots like
/// "Cars 🚗" carry `children` subcategories ("Audi", "BMW", …). Either level's `slug` can be
/// passed to the wallpaper endpoints as `categorySlug`.
struct WallpaperCategory: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let slug: String
    let children: [WallpaperCategory]

    enum CodingKeys: String, CodingKey { case id, name, slug, children }

    init(id: Int, name: String, slug: String, children: [WallpaperCategory] = []) {
        self.id = id
        self.name = name
        self.slug = slug
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decode(String.self, forKey: .slug)
        children = (try? c.decodeIfPresent([WallpaperCategory].self, forKey: .children)) ?? []
    }
}

struct CategoryListResponse: Decodable {
    let data: [WallpaperCategory]
}
