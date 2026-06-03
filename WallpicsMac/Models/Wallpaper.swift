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
    let wallpaper: String?        // present for photos (type 5); omitted for live/shader
    let thumbnail: String
    let video: String?            // live wallpapers (type 6): the .mp4 asset
    let wallpaperFile: String?    // shader wallpapers (type 7): the .zip bundle
    let staticThumbnail: String?  // live wallpapers: a still poster (jpg) for the first frame
    let createdAt: String?
    let downloadCount: Int?
    let hotRank: Int?
    let position: Int?
    let isLiked: Bool?
    let author: String?
    let categories: [Category]?
    let tags: [Tag]?

    /// What kind of wallpaper this is, from the backend `type` (5 = photo, 6 = live, 7 = shader).
    enum MediaType { case photo, live, shader }
    var mediaType: MediaType {
        switch type {
        case 6: return .live
        case 7: return .shader
        default: return .photo
        }
    }

    var wallpaperURL: URL? { wallpaper.flatMap { $0.isEmpty ? nil : URL(string: $0) } }

    /// Grid thumbnail. Live wallpapers ship an animated .webp `thumbnail` that AppKit can't
    /// animate, so prefer their still `static_thumbnail` for a clean, reliable preview.
    var thumbnailURL: URL? {
        if mediaType == .live, let s = staticThumbnail, !s.isEmpty { return URL(string: s) }
        return thumbnail.isEmpty ? nil : URL(string: thumbnail)
    }

    /// The remote asset to download when setting this wallpaper: image, .mp4 video, or .zip shader.
    var assetURL: URL? {
        switch mediaType {
        case .photo: return wallpaperURL
        case .live: return video.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        case .shader: return wallpaperFile.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
    }

    /// A still image used as the first frame behind animated/shader wallpapers.
    var posterURL: URL? {
        if let s = staticThumbnail, !s.isEmpty { return URL(string: s) }
        return thumbnailURL
    }

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
            video: nil,
            wallpaperFile: nil,
            staticThumbnail: nil,
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
             wallpaper, thumbnail, video, position, author, categories, tags
        case wallpaperFile = "wallpaper_file"
        case staticThumbnail = "static_thumbnail"
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
