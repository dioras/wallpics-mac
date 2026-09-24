import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Observation

enum PetCatalog {
    @MainActor
    static var all: [PetSpecies] { RemotePetService.shared.pets }

    @MainActor
    static func species(slug: String) -> PetSpecies? {
        all.first { $0.slug == slug }
    }
}

@MainActor
@Observable
final class RemotePetService {
    static let shared = RemotePetService()
    static let didUpdate = Notification.Name("RemotePetServiceDidUpdate")

    private(set) var pets: [PetSpecies] = []
    private(set) var communityIDs: Set<Int> = RemotePetService.cachedCommunityIDs() {
        didSet { UserDefaults.standard.set(communityIDs.sorted(), forKey: Self.communityKey) }
    }
    private static let communityKey = "diyCommunityPetIDs"

    private static func cachedCommunityIDs() -> Set<Int> {
        Set((UserDefaults.standard.array(forKey: communityKey) as? [Int]) ?? [])
    }
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var mediaTasks: [URL: Task<URL, Error>] = [:]

    private static let listURL = URL(string: "https://backend.wallpics.app/api/pets")!
    private static var unreachableMessage: String {
        String(localized: "Couldn't reach WallPics. Check your connection and try again.")
    }
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
        let data: [LossyPet]
        let info: PageInfo?
    }

    private struct LossyPet: Decodable {
        let pet: RemotePet?

        init(from decoder: Decoder) throws {
            do {
                pet = try RemotePet(from: decoder)
            } catch {
                Log.api.error("RemotePetService: skipping undecodable pet entry — \(String(describing: error), privacy: .public)")
                pet = nil
            }
        }
    }

    private struct RemotePet: Codable {
        struct Point: Codable {
            let x: Double
            let y: Double
        }
        struct SideTransitions: Codable {
            let poseCount: Int?
            let pivotRight: Int?
            let pivotLeft: Int?
            let topStart: Int?
            let topEnd: Int?
            let rightStart: Int?
            let rightEnd: Int?
            let bottomStart: Int?
            let bottomEnd: Int?
            let leftStart: Int?
            let leftEnd: Int?
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
            let loopStart: Int?
            let loopEnd: Int?
            let pettingAppropriate: Bool?
            let sideTransitionData: SideTransitions?

            enum CodingKeys: String, CodingKey {
                case poseCount, neutralPose, faceCenter, angleBuckets, angleTable, mirrorTable
                case pivotUp, pivotDown, subjectHeight, subjectBottom, wraps, loopStart, loopEnd
                case pettingAppropriate, sideTransitionData
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                poseCount = try c.decode(Int.self, forKey: .poseCount)
                neutralPose = try c.decode(Int.self, forKey: .neutralPose)
                faceCenter = try c.decode(Point.self, forKey: .faceCenter)
                angleBuckets = try c.decode(Int.self, forKey: .angleBuckets)
                angleTable = try c.decode([Int].self, forKey: .angleTable)
                mirrorTable = try c.decodeIfPresent([Bool].self, forKey: .mirrorTable)
                pivotUp = try c.decodeIfPresent(Int.self, forKey: .pivotUp)
                pivotDown = try c.decodeIfPresent(Int.self, forKey: .pivotDown)
                subjectHeight = try c.decodeIfPresent(Double.self, forKey: .subjectHeight)
                subjectBottom = try c.decodeIfPresent(Double.self, forKey: .subjectBottom)
                wraps = try c.decodeIfPresent(Bool.self, forKey: .wraps)
                loopStart = try c.decodeIfPresent(Int.self, forKey: .loopStart)
                loopEnd = try c.decodeIfPresent(Int.self, forKey: .loopEnd)
                do {
                    pettingAppropriate = try c.decodeIfPresent(Bool.self, forKey: .pettingAppropriate)
                } catch {
                    Log.api.error("RemotePetService: unreadable pettingAppropriate — \(String(describing: error), privacy: .public)")
                    pettingAppropriate = nil
                }
                do {
                    sideTransitionData = try c.decodeIfPresent(SideTransitions.self, forKey: .sideTransitionData)
                } catch {
                    Log.api.error("RemotePetService: unreadable sideTransitionData — \(String(describing: error), privacy: .public)")
                    sideTransitionData = nil
                }
            }
        }
        let id: Int
        let name: String?
        let description: String?
        let isPremium: Bool?
        let video: URL
        let videoMov: URL?
        let thumbnail: URL
        let gaze: Gaze
        let sideVideoMov: URL?
        let pettingVideoMov: URL?

        enum CodingKeys: String, CodingKey {
            case id, name, description, video, thumbnail, gaze
            case isPremium = "is_premium"
            case videoMov = "video_mov"
            case sideVideoMov = "side_video_mov"
            case pettingVideoMov = "petting_video_mov"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let petID = try c.decode(Int.self, forKey: .id)
            id = petID
            name = try c.decodeIfPresent(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            isPremium = try c.decodeIfPresent(Bool.self, forKey: .isPremium)
            video = try c.decode(URL.self, forKey: .video)
            videoMov = try c.decodeIfPresent(URL.self, forKey: .videoMov)
            thumbnail = try c.decode(URL.self, forKey: .thumbnail)
            gaze = try c.decode(Gaze.self, forKey: .gaze)
            do {
                sideVideoMov = try c.decodeIfPresent(URL.self, forKey: .sideVideoMov)
            } catch {
                Log.api.error("RemotePetService: pet \(petID) has an unreadable side_video_mov — \(String(describing: error), privacy: .public)")
                sideVideoMov = nil
            }
            do {
                pettingVideoMov = try c.decodeIfPresent(URL.self, forKey: .pettingVideoMov)
            } catch {
                Log.api.error("RemotePetService: pet \(petID) has an unreadable petting_video_mov — \(String(describing: error), privacy: .public)")
                pettingVideoMov = nil
            }
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
        isRefreshing = true
        defer { isRefreshing = false }
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
            guard !loaded.isEmpty else {
                lastError = Self.unreachableMessage
                Log.api.error("RemotePetService: refresh produced no usable pets (\(remotePets.count) listed), keeping \(self.pets.count) cached")
                return
            }
            pets = loaded
            lastError = nil
            await refreshCommunity()
            Log.api.info("RemotePetService: loaded \(loaded.count) pets from \(pageCount) page(s)")
            NotificationCenter.default.post(name: Self.didUpdate, object: nil)
        } catch {
            lastError = Self.unreachableMessage
            Log.api.error("RemotePetService: listing failed — \(String(describing: error), privacy: .public)")
        }
    }

    private struct IDListing: Decodable {
        struct Entry: Decodable { let id: Int }
        struct PageInfo: Decodable {
            let currentPage: Int
            let lastPage: Int

            enum CodingKeys: String, CodingKey {
                case currentPage = "current_page"
                case lastPage = "last_page"
            }
        }
        let data: [Entry]
        let info: PageInfo?
    }

    private func refreshCommunity() async {
        let timestamp = Int(Date().timeIntervalSince1970)
        var ids: Set<Int> = []
        var page = 1
        do {
            while page <= Self.maxPages {
                let data = try await fetchPage(page: page, timestamp: timestamp,
                                               categoryID: PetDIY.communityCategoryID)
                let listing = try JSONDecoder().decode(IDListing.self, from: data)
                ids.formUnion(listing.data.map(\.id))
                guard let info = listing.info, info.currentPage < info.lastPage else { break }
                page += 1
            }
            communityIDs = ids
        } catch {
            Log.api.error("RemotePetService: DIY list failed, keeping \(self.communityIDs.count) cached — \(String(describing: error), privacy: .public)")
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
            for pet in listing.data.compactMap(\.pet) where seen.insert(pet.id).inserted {
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
        let data = try await fetchPage(page: page, timestamp: timestamp, categoryID: nil)
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    private func fetchPage(page: Int, timestamp: Int, categoryID: Int?) async throws -> Data {
        var components = URLComponents(url: Self.listURL, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "paginated", value: "1"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            URLQueryItem(name: "timestamp", value: String(timestamp))
        ]
        if let categoryID {
            items.append(URLQueryItem(name: "categoryId", value: String(categoryID)))
        }
        components?.queryItems = items
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
        return data
    }

    private func materialize(_ pet: RemotePet) async throws -> PetSpecies {
        let dir = try Self.cacheDir(petId: pet.id)
        let source = pet.videoMov ?? pet.video
        Self.evictStaleMedia(in: dir, source: source, thumbnail: pet.thumbnail)
        Self.evictStaleTransitions(in: dir, pet: pet)
        _ = try await cachedFile(remote: pet.thumbnail, in: dir, name: "poster.png",
                                 mimePrefix: "image/")
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        _ = try await cachedFile(remote: source, in: dir, name: "pet." + ext,
                                 mimePrefix: "video/")
        if let meta = try? JSONEncoder().encode(pet) {
            try? meta.write(to: dir.appendingPathComponent("meta.json"))
        }
        return try Self.buildSpecies(pet: pet, dir: dir)
    }

    private static func evictStaleMedia(in dir: URL, source: URL, thumbnail: URL) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let cached = try? JSONDecoder().decode(RemotePet.self, from: data) else { return }
        let cachedSource = cached.videoMov ?? cached.video
        if cachedSource != source, let media = mediaFile(in: dir) {
            try? fm.removeItem(at: media)
            Log.api.info("RemotePetService: pet \(cached.id) video changed, re-downloading")
        }
        if cached.thumbnail != thumbnail {
            try? fm.removeItem(at: dir.appendingPathComponent("poster.png"))
        }
    }

    private static let sideFileName = "side.mov"
    private static let pettingFileName = "petting.mov"

    private static func evictStaleTransitions(in dir: URL, pet: RemotePet) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let cached = try? JSONDecoder().decode(RemotePet.self, from: data) else { return }
        let fm = FileManager.default
        if cached.sideVideoMov != pet.sideVideoMov {
            try? fm.removeItem(at: dir.appendingPathComponent(sideFileName))
        }
        if cached.pettingVideoMov != pet.pettingVideoMov {
            try? fm.removeItem(at: dir.appendingPathComponent(pettingFileName))
        }
    }

    func transitionMedia(for transitions: PetTransitions) async -> (side: URL, petting: URL?)? {
        let dir = transitions.cacheDirectory
        do {
            let side = try await sharedDownload(remote: transitions.sideRemoteURL, in: dir, name: Self.sideFileName)
            var petting: URL?
            if let remote = transitions.pettingRemoteURL {
                do {
                    petting = try await sharedDownload(remote: remote, in: dir, name: Self.pettingFileName)
                } catch {
                    Log.api.error("RemotePetService: petting clip unavailable — \(String(describing: error), privacy: .public)")
                }
            }
            return (side, petting)
        } catch {
            Log.api.error("RemotePetService: side clips unavailable — \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func sharedDownload(remote: URL, in dir: URL, name: String) async throws -> URL {
        let key = dir.appendingPathComponent(name)
        if let pending = mediaTasks[key] { return try await pending.value }
        let task = Task { try await cachedFile(remote: remote, in: dir, name: name, mimePrefix: "video/") }
        mediaTasks[key] = task
        defer { mediaTasks[key] = nil }
        return try await task.value
    }

    private static func transitions(for pet: RemotePet, dir: URL, angleTable: [Int],
                                    loop: ClosedRange<Int>?) -> PetTransitions? {
        guard let remote = pet.sideVideoMov, let side = pet.gaze.sideTransitionData else { return nil }
        guard let loop else {
            Log.api.error("RemotePetService: pet \(pet.id) has side clips but no 360 loop, keeping the classic return")
            return nil
        }
        var clips: [PetReturnClip] = []
        func add(_ direction: PetTurnDirection, _ start: Int?, _ end: Int?, _ pivot: Int?) {
            guard let start, let end, start >= 0, end > start, side.poseCount.map({ end < $0 }) ?? true else {
                Log.api.error("RemotePetService: pet \(pet.id) \(direction.rawValue, privacy: .public) clip has an invalid range, skipped")
                return
            }
            guard let resolved = pivot ?? GazeMap.pose(forAngle: direction.angle, table: angleTable),
                  loop.contains(resolved) else {
                Log.api.error("RemotePetService: pet \(pet.id) \(direction.rawValue, privacy: .public) pivot is outside the 360 loop, skipped")
                return
            }
            clips.append(PetReturnClip(direction: direction, pivot: resolved, frames: start...end))
        }
        add(.up, side.topStart, side.topEnd, pet.gaze.pivotUp)
        add(.right, side.rightStart, side.rightEnd, side.pivotRight)
        add(.down, side.bottomStart, side.bottomEnd, pet.gaze.pivotDown)
        add(.left, side.leftStart, side.leftEnd, side.pivotLeft)
        guard !clips.isEmpty else {
            Log.api.error("RemotePetService: pet \(pet.id) has side clips but none are usable")
            return nil
        }
        let petting = pet.gaze.pettingAppropriate == false ? nil : pet.pettingVideoMov
        return PetTransitions(clips: clips, sideRemoteURL: remote, pettingRemoteURL: petting, cacheDirectory: dir)
    }

    private static func mediaFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        let preferred = dir.appendingPathComponent("pet.mov")
        if fm.fileExists(atPath: preferred.path) { return preferred }
        return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("pet.") && $0.pathExtension != "json" }
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
        guard let mediaURL = mediaFile(in: dir) else {
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
        let angleTable = gaze.angleTable.map(clamp)
        var gazeLoop: ClosedRange<Int>?
        if wraps, let start = gaze.loopStart, let end = gaze.loopEnd, start < end {
            gazeLoop = clamp(start)...clamp(end)
        }
        let summary = pet.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = pet.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PetSpecies(
            slug: PetSpecies.remoteSlug(id: pet.id),
            name: trimmedName.isEmpty ? String(localized: "Pet \(pet.id)") : trimmedName,
            pixelWidth: width,
            pixelHeight: height,
            poseCount: gaze.poseCount,
            neutralPose: clamp(gaze.neutralPose),
            faceCenter: CGPoint(x: gaze.faceCenter.x, y: gaze.faceCenter.y),
            subjectHeight: CGFloat(min(max(gaze.subjectHeight ?? 1, 0.2), 1)),
            subjectBottom: CGFloat(min(max(gaze.subjectBottom ?? 1, 0.2), 1)),
            angleTable: angleTable,
            mirrorTable: mirrorTable,
            pivotUp: clamp(gaze.pivotUp ?? gaze.neutralPose),
            pivotDown: clamp(gaze.pivotDown ?? gaze.neutralPose),
            wrapsAround: wraps,
            gazeLoop: gazeLoop,
            isPremium: pet.isPremium ?? false,
            summary: (summary?.isEmpty ?? true) ? nil : summary,
            mediaURL: mediaURL,
            posterURL: posterURL,
            transitions: transitions(for: pet, dir: dir, angleTable: angleTable, loop: gazeLoop)
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
