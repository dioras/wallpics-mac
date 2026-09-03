import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum PetCatalog {
    private struct CatalogFile: Decodable {
        struct Entry: Decodable {
            let slug: String
            let name: String
        }
        let pets: [Entry]
    }

    private struct PetFile: Decodable {
        struct Point: Decodable {
            let x: Double
            let y: Double
        }
        let slug: String
        let name: String
        let width: Int
        let height: Int
        let poseCount: Int
        let neutralPose: Int
        let faceCenter: Point
        let subjectHeight: Double?
        let subjectBottom: Double?
        let angleBuckets: Int
        let angleTable: [Int]
        let mirrorTable: [Bool]?
        let pivotUp: Int?
        let pivotDown: Int?
        let wraps: Bool?
    }

    static let bundled: [PetSpecies] = load()

    @MainActor
    static var all: [PetSpecies] { bundled + RemotePetService.shared.pets }

    @MainActor
    static func species(slug: String) -> PetSpecies? {
        all.first { $0.slug == slug }
    }

    private static var root: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Pets", isDirectory: true)
    }

    private static func load() -> [PetSpecies] {
        guard let root else {
            Log.app.error("PetCatalog: no resource root")
            return []
        }
        let catalogURL = root.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode(CatalogFile.self, from: data) else {
            Log.app.error("PetCatalog: cannot read \(catalogURL.path, privacy: .public)")
            return []
        }
        return catalog.pets.compactMap { entry in
            let dir = root.appendingPathComponent(entry.slug, isDirectory: true)
            let metaURL = dir.appendingPathComponent("pet.json")
            let mediaURL = dir.appendingPathComponent("pet.mov")
            let posterURL = dir.appendingPathComponent("poster.png")
            guard let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(PetFile.self, from: metaData) else {
                Log.app.error("PetCatalog: cannot read metadata for \(entry.slug, privacy: .public)")
                return nil
            }
            guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                Log.app.error("PetCatalog: missing media for \(entry.slug, privacy: .public)")
                return nil
            }
            let mirrorCount = meta.mirrorTable?.count ?? meta.angleBuckets
            guard meta.angleTable.count == meta.angleBuckets,
                  mirrorCount == meta.angleBuckets,
                  meta.poseCount > 0 else {
                Log.app.error("PetCatalog: malformed gaze map for \(entry.slug, privacy: .public)")
                return nil
            }
            return PetSpecies(
                slug: meta.slug,
                name: entry.name,
                pixelWidth: meta.width,
                pixelHeight: meta.height,
                poseCount: meta.poseCount,
                neutralPose: meta.neutralPose,
                faceCenter: CGPoint(x: meta.faceCenter.x, y: meta.faceCenter.y),
                subjectHeight: CGFloat(min(max(meta.subjectHeight ?? 1, 0.2), 1)),
                subjectBottom: CGFloat(min(max(meta.subjectBottom ?? 1, 0.2), 1)),
                angleTable: meta.angleTable,
                mirrorTable: meta.mirrorTable ?? Array(repeating: false, count: meta.angleTable.count),
                pivotUp: meta.pivotUp ?? meta.neutralPose,
                pivotDown: meta.pivotDown ?? meta.neutralPose,
                wrapsAround: meta.wraps ?? false,
                mediaURL: mediaURL,
                posterURL: posterURL
            )
        }
    }
}


@MainActor
final class RemotePetService {
    static let shared = RemotePetService()
    static let didUpdate = Notification.Name("RemotePetServiceDidUpdate")

    private(set) var pets: [PetSpecies] = []
    private var refreshTask: Task<Void, Never>?

    private static let listURL = URL(string: "https://backend.wallpics.app/api/pets")!
    private static let pageSize = 24
    private static let maxPages = 20

    private init() {
        pets = Self.hydrateFromDisk()
    }

    private struct Listing: Decodable {
        struct PageInfo: Decodable {
            let currentPage: Int
            let lastPage: Int

            enum CodingKeys: String, CodingKey {
                case currentPage = "current_page"
                case lastPage = "last_page"
            }
        }
        let status: String
        let data: [RemotePet]
        let info: PageInfo?
    }

    private struct RemotePet: Codable {
        struct Point: Codable {
            let x: Double
            let y: Double
        }
        struct Gaze: Codable {
            let poseCount: Int
            let neutralPose: Int
            let faceCenter: Point
            let angleBuckets: Int
            let angleTable: [Int]
            let mirrorTable: [Bool]?
            let pivotUp: Int?
            let pivotDown: Int?
            let subjectHeight: Double?
            let subjectBottom: Double?
            let wraps: Bool?
        }
        let id: Int
        let name: String
        let description: String?
        let isPremium: Bool?
        let video: URL
        let videoMov: URL?
        let thumbnail: URL
        let gaze: Gaze

        enum CodingKeys: String, CodingKey {
            case id, name, description, video, thumbnail, gaze
            case isPremium = "is_premium"
            case videoMov = "video_mov"
        }
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        do {
            let (remotePets, pageCount) = try await fetchAllPages()
            var loaded: [PetSpecies] = []
            for pet in remotePets {
                do {
                    loaded.append(try await materialize(pet))
                } catch {
                    Log.api.error("RemotePetService: pet \(pet.id) skipped — \(String(describing: error), privacy: .public)")
                }
            }
            pets = loaded
            Log.api.info("RemotePetService: loaded \(loaded.count) pets from \(pageCount) page(s)")
            NotificationCenter.default.post(name: Self.didUpdate, object: nil)
        } catch {
            Log.api.error("RemotePetService: listing failed — \(String(describing: error), privacy: .public)")
        }
    }

    private func fetchAllPages() async throws -> ([RemotePet], Int) {
        let timestamp = Int(Date().timeIntervalSince1970)
        var collected: [RemotePet] = []
        var seen: Set<Int> = []
        var pagesFetched = 0
        var page = 1
        while page <= Self.maxPages {
            let listing = try await fetchListing(page: page, timestamp: timestamp)
            pagesFetched += 1
            for pet in listing.data where seen.insert(pet.id).inserted {
                collected.append(pet)
            }
            guard let info = listing.info else {
                Log.api.notice("RemotePetService: listing has no page info, stopping after page \(page)")
                break
            }
            guard info.currentPage < info.lastPage else { break }
            page += 1
        }
        if page > Self.maxPages {
            Log.api.error("RemotePetService: stopped after \(Self.maxPages) pages, catalog truncated")
        }
        return (collected, pagesFetched)
    }

    private func fetchListing(page: Int, timestamp: Int) async throws -> Listing {
        var components = URLComponents(url: Self.listURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "paginated", value: "1"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            URLQueryItem(name: "timestamp", value: String(timestamp))
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        let time = String(Int(Date().timeIntervalSince1970))
        let token = Insecure.MD5.hash(data: Data((time + "wall").utf8))
            .map { String(format: "%02x", $0) }.joined()
        request.setValue(time, forHTTPHeaderField: "x-auth")
        request.setValue(token, forHTTPHeaderField: "x-token")
        request.setValue("1", forHTTPHeaderField: "x-get-guest-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    private func materialize(_ pet: RemotePet) async throws -> PetSpecies {
        let dir = try Self.cacheDir(petId: pet.id)
        _ = try await cachedFile(remote: pet.thumbnail, in: dir, name: "poster.png",
                                 mimePrefix: "image/")
        let source = pet.videoMov ?? pet.video
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        _ = try await cachedFile(remote: source, in: dir, name: "pet." + ext,
                                 mimePrefix: "video/")
        if let meta = try? JSONEncoder().encode(pet) {
            try? meta.write(to: dir.appendingPathComponent("meta.json"))
        }
        return try Self.buildSpecies(pet: pet, dir: dir)
    }

    private struct GazeOverride: Decodable {
        let invertMirror: Bool?
    }

    private static func buildSpecies(pet: RemotePet, dir: URL) throws -> PetSpecies {
        let gaze = pet.gaze
        let mirrorCount = gaze.mirrorTable?.count ?? gaze.angleBuckets
        guard gaze.angleTable.count == gaze.angleBuckets,
              mirrorCount == gaze.angleBuckets,
              gaze.poseCount > 0 else {
            throw URLError(.cannotParseResponse)
        }
        let override = (try? Data(contentsOf: dir.appendingPathComponent("override.json")))
            .flatMap { try? JSONDecoder().decode(GazeOverride.self, from: $0) }
        let fm = FileManager.default
        let posterURL = dir.appendingPathComponent("poster.png")
        guard fm.fileExists(atPath: posterURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        let preferred = dir.appendingPathComponent("pet.mov")
        let mediaURL: URL
        if fm.fileExists(atPath: preferred.path) {
            mediaURL = preferred
        } else if let found = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("pet.") && $0.pathExtension != "json" }) {
            mediaURL = found
        } else {
            throw URLError(.fileDoesNotExist)
        }
        guard let source = CGImageSourceCreateWithURL(posterURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        let clamp = { (v: Int) in min(max(v, 0), gaze.poseCount - 1) }
        var mirrorTable = gaze.mirrorTable ?? Array(repeating: false, count: gaze.angleTable.count)
        if override?.invertMirror == true {
            mirrorTable = mirrorTable.map { !$0 }
        }
        let wraps = gaze.wraps ?? false
        var angleTable = gaze.angleTable.map(clamp)
        var gazeLoop: ClosedRange<Int>?
        var pivotUp = clamp(gaze.pivotUp ?? gaze.neutralPose)
        var pivotDown = clamp(gaze.pivotDown ?? gaze.neutralPose)
        if wraps {
            let repaired = GazeTableRepair.circular(angleTable, poseCount: gaze.poseCount)
            if repaired.replacedBuckets > 0 {
                Log.api.info("RemotePetService: pet \(pet.id) gaze table repaired, \(repaired.replacedBuckets) buckets replaced, loop \(repaired.loop.lowerBound)-\(repaired.loop.upperBound)")
            }
            angleTable = repaired.table
            gazeLoop = repaired.loop
        } else {
            let pivots = GazeTableRepair.pivots(for: angleTable, fallback: gaze.neutralPose)
            pivotUp = clamp(pivots.up)
            pivotDown = clamp(pivots.down)
        }
        let summary = pet.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetSpecies(
            slug: "remote-\(pet.id)",
            name: pet.name,
            pixelWidth: width,
            pixelHeight: height,
            poseCount: gaze.poseCount,
            neutralPose: clamp(gaze.neutralPose),
            faceCenter: CGPoint(x: gaze.faceCenter.x, y: gaze.faceCenter.y),
            subjectHeight: CGFloat(min(max(gaze.subjectHeight ?? 1, 0.2), 1)),
            subjectBottom: CGFloat(min(max(gaze.subjectBottom ?? 1, 0.2), 1)),
            angleTable: angleTable,
            mirrorTable: mirrorTable,
            pivotUp: pivotUp,
            pivotDown: pivotDown,
            wrapsAround: wraps,
            gazeLoop: gazeLoop,
            isPremium: pet.isPremium ?? false,
            summary: (summary?.isEmpty ?? true) ? nil : summary,
            mediaURL: mediaURL,
            posterURL: posterURL
        )
    }

    private static func hydrateFromDisk() -> [PetSpecies] {
        guard let base = try? cacheBase(),
              let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let pet = try? JSONDecoder().decode(RemotePet.self, from: data) else {
                return nil
            }
            return try? buildSpecies(pet: pet, dir: dir)
        }
    }

    private static func cacheBase() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("RemotePets", isDirectory: true)
    }

    private static func cacheDir(petId: Int) throws -> URL {
        let dir = try cacheBase().appendingPathComponent("pet-\(petId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cachedFile(remote: URL, in dir: URL, name: String, mimePrefix: String) async throws -> URL {
        let target = dir.appendingPathComponent(name)
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
           size > 0 {
            return target
        }
        let (temp, response) = try await URLSession.shared.download(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.mimeType?.hasPrefix(mimePrefix) == true else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}
