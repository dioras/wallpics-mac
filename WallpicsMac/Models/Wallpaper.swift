import Foundation

struct Wallpaper: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let slug: String
    let description: String?
    let type: Int
    let isPremium: Int
    let nsfw: Int
    let width: Int
    let height: Int
    let wallpaper: String
    let thumbnail: String
    let createdAt: String?
    let downloadCount: Int?
    let hotRank: Int?
    let position: Int?
    let isLiked: Bool?
    let author: String?
    let categories: [Category]?
    let tags: [Tag]?

    var wallpaperURL: URL? { URL(string: wallpaper) }
    var thumbnailURL: URL? { thumbnail.isEmpty ? nil : URL(string: thumbnail) }
    var isPremiumContent: Bool { isPremium == 1 }
    var aspectRatio: CGFloat { height == 0 ? 1 : CGFloat(width) / CGFloat(height) }
    var safeDescription: String { description ?? "" }
    var safeAuthor: String { author ?? "Unknown" }
    var safeTags: [Tag] { tags ?? [] }
    var safeDownloadCount: Int { downloadCount ?? 0 }

    /// A user-imported wallpaper stored on disk (negative id, file:// URLs).
    var isLocal: Bool { id < 0 || (wallpaperURL?.isFileURL ?? false) }

    /// Build a Wallpaper that points at a local file the user imported.
    static func local(id: Int, name: String, fileURL: URL, thumbnailURL: URL?, width: Int, height: Int) -> Wallpaper {
        Wallpaper(
            id: id,
            name: name,
            slug: "import-\(id)",
            description: nil,
            type: 0,
            isPremium: 0,
            nsfw: 0,
            width: width,
            height: height,
            wallpaper: fileURL.absoluteString,
            thumbnail: thumbnailURL?.absoluteString ?? "",
            createdAt: nil,
            downloadCount: nil,
            hotRank: nil,
            position: nil,
            isLiked: nil,
            author: "You",
            categories: nil,
            tags: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, description, type, nsfw, width, height,
             wallpaper, thumbnail, position, author, categories, tags
        case isPremium = "is_premium"
        case createdAt = "created_at"
        case downloadCount = "download_count"
        case hotRank = "hot_rank"
        case isLiked = "is_liked"
    }

    struct Category: Codable, Hashable {
        let id: Int
        let name: String
        let slug: String
    }

    struct Tag: Codable, Hashable {
        let id: Int
        let name: String
    }
}

struct WallpaperPage: Decodable {
    let data: [Wallpaper]
    let info: PageInfo

    struct PageInfo: Decodable {
        let currentPage: Int
        let lastPage: Int

        enum CodingKeys: String, CodingKey {
            case currentPage = "current_page"
            case lastPage = "last_page"
        }
    }
}
