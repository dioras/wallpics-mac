import Foundation
import CryptoKit
import os

actor WallpaperAPI {
    static let shared = WallpaperAPI()

    private let baseURL = URL(string: "https://backend.wallpics.app")!
    private let session: URLSession
    private let decoder: JSONDecoder
    private var guestID: String?

    private static let guestIDKey = "guest_id"
    private static let salt = "wall"

    enum APIError: LocalizedError {
        case invalidURL
        case http(Int)
        case decoding(Error)
        case transport(Error)
        case noGuestID

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "Invalid request URL.")
            case .http(let code): return String(localized: "Server returned status \(code).")
            case .decoding: return String(localized: "Could not read server response.")
            case .transport: return String(localized: "Network problem. Check your connection.")
            case .noGuestID: return String(localized: "Could not initialize session.")
            }
        }
    }

    init(session: URLSession = .shared) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        self.guestID = KeychainStore.string(for: Self.guestIDKey)
    }

    // MARK: - Guest

    @discardableResult
    func ensureGuestID() async throws -> String {
        if let existing = guestID { return existing }

        let url = baseURL.appendingPathComponent("api/init-guest")
        var req = URLRequest(url: url)
        applyAuthHeaders(to: &req, requestNewGuest: true)

        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)

        struct InitResponse: Decodable { let data: Inner; struct Inner: Decodable { let guestId: String } }
        let parsed = try decoder.decode(InitResponse.self, from: data)
        let id = parsed.data.guestId
        KeychainStore.set(id, for: Self.guestIDKey)
        guestID = id
        Log.api.debug("Guest ID provisioned")
        return id
    }

    // MARK: - Wallpapers

    func desktopWallpapers(collection: WallpaperCollection = .normal, page: Int, perPage: Int = 24, sortOrder: SortOrder = .newest, categorySlug: String? = nil, timestamp: Int? = nil) async throws -> WallpaperPage {
        _ = try await ensureGuestID()

        var components = URLComponents(url: baseURL.appendingPathComponent(collection.path), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "paginated", value: "1"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "sortBy", value: sortOrder.sortByValue),
            URLQueryItem(name: "sortOrder", value: sortOrder.queryValue),
            URLQueryItem(name: "nsfwContent", value: "0")
        ]
        // A stable timestamp across pages keeps a live catalog from shuffling between page
        // fetches (the backend uses it to freeze the ordering), so pages don't overlap/skip.
        if let timestamp {
            items.append(URLQueryItem(name: "timestamp", value: String(timestamp)))
        }
        if let slug = categorySlug, !slug.isEmpty {
            items.append(URLQueryItem(name: "categorySlug", value: slug))
        }
        components.queryItems = items

        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        applyAuthHeaders(to: &req)

        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)

        do {
            return try decoder.decode(WallpaperPage.self, from: data)
        } catch {
            Log.api.error("Wallpaper page decode failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.decoding(error)
        }
    }

    /// Category tree for the browse chips, scoped to a desktop wallpaper `type`
    /// (5 photo / 6 live / 7 shader). The backend's `type` filter returns ONLY categories that
    /// actually have content of that type, so each tab shows its own real categories with matching
    /// slugs — clicking one returns wallpapers instead of an empty grid. NOTE: sending `modelType`
    /// alongside `type` makes the backend ignore `type` and return the photo set on every tab
    /// (the old bug: Live/Shader showed photo categories that then matched nothing).
    func categoryList(type: Int? = nil) async throws -> [WallpaperCategory] {
        _ = try await ensureGuestID()
        var components = URLComponents(url: baseURL.appendingPathComponent("api/category-list"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "noComputed", value: "1")]
        if let type {
            items.append(URLQueryItem(name: "type", value: String(type)))
        } else {
            items.append(URLQueryItem(name: "modelType", value: "desktop_wallpaper"))
        }
        components.queryItems = items
        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        applyAuthHeaders(to: &req)
        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)
        do {
            return try decoder.decode(CategoryListResponse.self, from: data).data
        } catch {
            Log.api.error("Category list decode failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.decoding(error)
        }
    }

    // MARK: - Widgets (backend-driven catalog)

    func widgetCategories() async throws -> [WidgetCategoryNode] {
        _ = try await ensureGuestID()
        var components = URLComponents(url: baseURL.appendingPathComponent("api/category-list"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "modelType", value: "widget")]
        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        applyAuthHeaders(to: &req)
        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)
        do {
            return try decoder.decode(WidgetCategoryTreeRes.self, from: data).data ?? []
        } catch {
            Log.api.error("Widget categories decode failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.decoding(error)
        }
    }

    func widgets(categorySlug: String? = nil, query: String? = nil, page: Int = 1, perPage: Int = 24) async throws -> [WidgetCatalogItem] {
        _ = try await ensureGuestID()
        var components = URLComponents(url: baseURL.appendingPathComponent("api/widgets"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "paginated", value: "1"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        if let slug = categorySlug, !slug.isEmpty {
            items.append(URLQueryItem(name: "categorySlug", value: slug))
        }
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }
        components.queryItems = items
        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        applyAuthHeaders(to: &req)
        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)
        do {
            return try decoder.decode(WidgetCatalogRes.self, from: data).data ?? []
        } catch {
            Log.api.error("Widgets decode failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.decoding(error)
        }
    }

    /// The ENTIRE widget gallery, every category and type. The flat /api/widgets endpoint caps at
    /// ~32, but category-list-with-widgets exposes the whole catalog (125+ incl. world_cup_stats,
    /// stickers, animated) — flattened across the tree and de-duped by id.
    func allGalleryWidgets(perCategory: Int = 200) async throws -> [WidgetCatalogItem] {
        _ = try await ensureGuestID()
        var components = URLComponents(url: baseURL.appendingPathComponent("api/category-list-with-widgets"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "widgets_per_category", value: String(perCategory))]
        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        applyAuthHeaders(to: &req)
        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)
        let decoded: CategoryWidgetsRes
        do {
            decoded = try decoder.decode(CategoryWidgetsRes.self, from: data)
        } catch {
            Log.api.error("Gallery widgets decode failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.decoding(error)
        }
        var out: [WidgetCatalogItem] = []
        var seen = Set<String>()
        func walk(_ nodes: [CategoryWidgetsRes.Node]) {
            for node in nodes {
                for widget in node.widgets ?? [] where widget.id != nil {
                    if seen.insert(widget.id!).inserted { out.append(widget) }
                }
                if let children = node.children { walk(children) }
            }
        }
        walk(decoded.data ?? [])
        return out
    }

    func recordWidgetUse(widgetID: String) async {
        do {
            _ = try await ensureGuestID()
            let url = baseURL.appendingPathComponent("api/add_use/widget/\(widgetID)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            applyAuthHeaders(to: &req)
            _ = try await session.data(for: req)
        } catch {
            Log.api.debug("Widget use stat failed (non-fatal)")
        }
    }

    func downloadData(from url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        if let host = url.host?.lowercased(), host == "wallpics.app" || host.hasSuffix(".wallpics.app") {
            applyAuthHeaders(to: &req)
        }
        let (data, response) = try await transport { try await session.data(for: req) }
        try ensureOK(response)
        return data
    }

    func recordDownload(wallpaperID: Int) async {
        do {
            _ = try await ensureGuestID()
            let url = baseURL.appendingPathComponent("api/wallpapers/\(wallpaperID)/download")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            applyAuthHeaders(to: &req)
            _ = try await session.data(for: req)
        } catch {
            Log.api.debug("Download stat failed (non-fatal)")
        }
    }

    // MARK: - Image fetching

    func downloadImage(from url: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(1 << (attempt - 1)) * 1_000_000_000))
                if Task.isCancelled { throw CancellationError() }
            }
            do {
                let (tempURL, response) = try await session.download(from: url) { written, total in
                    guard total > 0 else { return }
                    progress?(Double(written) / Double(total))
                }
                try ensureOK(response)
                // Reject a confirmed empty file so a truncated asset never renders as a black wallpaper.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value, size == 0 {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw URLError(.zeroByteResource)
                }
                return tempURL
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch let error as APIError {
                if case .http(let code) = error, (400..<500).contains(code) { throw error }  // client error — fail fast
                lastError = error   // 5xx — retry
            } catch {
                if Task.isCancelled { throw error }
                if !ResilientFetch.isRetryable(error) { throw error }   // timed-out → don't repeat a long wait
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Helpers

    private func applyAuthHeaders(to request: inout URLRequest, requestNewGuest: Bool = false) {
        let ts = String(Int(Date().timeIntervalSince1970))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacOS", forHTTPHeaderField: "X-App-Platform")
        request.setValue(ts, forHTTPHeaderField: "x-auth")
        request.setValue(md5(ts + Self.salt), forHTTPHeaderField: "x-token")
        if let id = guestID {
            request.setValue(id, forHTTPHeaderField: "x-guest-id")
        }
        if requestNewGuest || guestID == nil {
            request.setValue("1", forHTTPHeaderField: "x-get-guest-id")
        }
    }

    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode)
        }
    }

    private func transport<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let urlError as URLError { throw APIError.transport(urlError) }
    }
}

/// The three desktop wallpaper collections served by the backend. Each maps to its own
/// endpoint but returns the identical `WallpaperPage` shape.
enum WallpaperCollection: String, CaseIterable, Identifiable, Sendable {
    case normal
    case live
    case shader

    var id: String { rawValue }

    var path: String {
        switch self {
        case .normal: return "api/wallpapers/desktop"
        case .live: return "api/wallpapers/live-desktop"
        case .shader: return "api/wallpapers/shader-desktop"
        }
    }

    /// Backend wallpaper `type` for this collection (used by category content counts).
    var apiType: Int {
        switch self {
        case .normal: return 5
        case .live: return 6
        case .shader: return 7
        }
    }

    var label: String {
        switch self {
        case .normal: return String(localized: "Photos")
        case .live: return String(localized: "Live")
        case .shader: return String(localized: "Shaders")
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "photo"
        case .live: return "play.circle"
        case .shader: return "sparkles"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case newest
    case oldest
    case popular

    var queryValue: String {
        switch self {
        case .newest, .popular: return "desc"
        case .oldest: return "asc"
        }
    }

    /// Backend sort field. The API sorts by `sortBy` (the field) + `sortOrder` (direction);
    /// sending only the direction leaves every option sorting by the default field, so
    /// "Most Popular" was identical to "Newest". Map each option to its real field.
    var sortByValue: String {
        switch self {
        case .newest, .oldest: return "date"
        case .popular: return "popular"
        }
    }

    var label: String {
        switch self {
        case .newest: return String(localized: "Newest First")
        case .oldest: return String(localized: "Oldest First")
        case .popular: return String(localized: "Most Popular")
        }
    }
}

private extension URLSession {
    func download(from url: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let request = URLRequest(url: url)
        return try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = downloadTask(with: request) { tempURL, response, error in
                observation?.invalidate() // retained until here so progress fires for the whole transfer
                observation = nil
                if let error = error {
                    continuation.resume(throwing: error); return
                }
                guard let tempURL = tempURL, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                let persistent = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: persistent)
                    continuation.resume(returning: (persistent, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                progress(Int64(p.completedUnitCount), Int64(p.totalUnitCount))
            }
            task.resume()
        }
    }
}
