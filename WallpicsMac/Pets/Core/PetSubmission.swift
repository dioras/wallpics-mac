import Foundation
import Observation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import CryptoKit

struct PetSubmissionPhoto: Sendable {
    let fileName: String
    let data: Data

    var digest: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PetSubmissionRules {
    static let maxPhotos = 5
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxLongEdge: CGFloat = 2048
    static let maxNameLength = 80
    static let maxNotesLength = 500

    static var maxFileMB: Int { maxFileBytes / (1024 * 1024) }
}

enum PetSubmissionError: LocalizedError, Equatable, Sendable {
    case noPhotos
    case tooManyPhotos(max: Int)
    case alreadySent
    case unreadable(String)
    case tooLarge(String, maxMB: Int)
    case server(String)
    case transport

    var errorDescription: String? {
        switch self {
        case .noPhotos:
            return String(localized: "Add at least one photo of your pet.")
        case .tooManyPhotos(let max):
            return String(localized: "You can send up to \(max) photos.")
        case .alreadySent:
            return String(localized: "You've already sent one of these photos. Each pet only needs to be sent once — it appears in your list after review.")
        case .unreadable(let file):
            return String(localized: "\(file) couldn't be read as an image.")
        case .tooLarge(let file, let maxMB):
            return String(localized: "\(file) is larger than \(maxMB) MB.")
        case .server(let message):
            return message
        case .transport:
            return String(localized: "Network problem. Check your connection.")
        }
    }
}

enum PetSubmissionPhotoPrep {
    static func prepare(url: URL) throws -> PetSubmissionPhoto {
        let label = url.lastPathComponent
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteCount <= PetSubmissionRules.maxFileBytes else {
            throw PetSubmissionError.tooLarge(label, maxMB: PetSubmissionRules.maxFileMB)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0
        else {
            throw PetSubmissionError.unreadable(label)
        }

        let longEdge = min(max(pixelWidth, pixelHeight), Int(PetSubmissionRules.maxLongEdge))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PetSubmissionError.unreadable(label)
        }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PetSubmissionError.unreadable(label)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), buffer.length > 0 else {
            throw PetSubmissionError.unreadable(label)
        }

        return PetSubmissionPhoto(fileName: safeFileName(for: url), data: buffer as Data)
    }

    static func safeFileName(for url: URL) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = url.deletingPathExtension().lastPathComponent
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(stem.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (cleaned.isEmpty ? "photo" : cleaned) + ".jpg"
    }
}

struct PetSubmissionRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let submittedAt: Date
    let photoCount: Int
    let serverPetID: Int?
}

private struct PetSubmissionsFile: Codable {
    static let currentVersion = 2
    static let maxRememberedDigests = 200

    var version: Int = currentVersion
    var records: [PetSubmissionRecord] = []
    var submissionCount: Int = 0
    var sentPhotoDigests: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        records = try c.decodeIfPresent([PetSubmissionRecord].self, forKey: .records) ?? []
        submissionCount = try c.decodeIfPresent(Int.self, forKey: .submissionCount) ?? records.count
        sentPhotoDigests = try c.decodeIfPresent([String].self, forKey: .sentPhotoDigests) ?? []
    }
}

@MainActor
@Observable
final class PetSubmissionStore {
    static let shared = PetSubmissionStore()

    private(set) var records: [PetSubmissionRecord] = []
    private(set) var submissionCount = 0
    private var sentPhotoDigests: [String] = []

    static var fileURL: URL { PetPaths.root.appendingPathComponent("submissions.json") }

    init() {
        let file = Self.load()
        records = file.records
        submissionCount = file.submissionCount
        sentPhotoDigests = file.sentPhotoDigests
    }

    func hasSent(digest: String) -> Bool {
        sentPhotoDigests.contains(digest)
    }

    @discardableResult
    func add(_ record: PetSubmissionRecord, photoDigests: [String]) -> Bool {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        submissionCount += 1
        sentPhotoDigests.append(contentsOf: photoDigests.filter { !sentPhotoDigests.contains($0) })
        if sentPhotoDigests.count > PetSubmissionsFile.maxRememberedDigests {
            sentPhotoDigests.removeFirst(sentPhotoDigests.count - PetSubmissionsFile.maxRememberedDigests)
        }
        return persist()
    }

    func remove(id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        persist()
    }

    func reconcile(approvedServerIDs: Set<Int>) {
        let resolved = records.filter { record in
            record.serverPetID.map(approvedServerIDs.contains) ?? false
        }
        guard !resolved.isEmpty else { return }
        records.removeAll { record in resolved.contains(record) }
        Log.app.info("PetSubmissionStore: \(resolved.count) submission(s) now live in the catalog")
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        var file = PetSubmissionsFile()
        file.records = records
        file.submissionCount = submissionCount
        file.sentPhotoDigests = sentPhotoDigests
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: Self.fileURL, options: .atomic)
            return true
        } catch {
            Log.app.error("PetSubmissionStore: failed to save submissions — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func load() -> PetSubmissionsFile {
        guard let data = try? Data(contentsOf: fileURL) else { return PetSubmissionsFile() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PetSubmissionsFile.self, from: data)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.app.error("PetSubmissionStore: unreadable submissions moved aside — \(error.localizedDescription, privacy: .public)")
            return PetSubmissionsFile()
        }
    }
}

@MainActor
@Observable
final class PetSubmissionModel {
    enum Phase: Equatable {
        case editing
        case uploading
        case done(PetSubmissionRecord)
        case failed(String)
    }

    var photoURLs: [URL] = []
    var thumbnails: [URL: NSImage] = [:]
    var name: String = ""
    var notes: String = ""
    var phase: Phase = .editing
    var notice: String?

    init() {}

    var canSubmit: Bool {
        (1...PetSubmissionRules.maxPhotos).contains(photoURLs.count) && phase == .editing
    }

    var isUploading: Bool { phase == .uploading }

    func addPhotos(_ urls: [URL]) {
        notice = nil
        var rejectedKind = false
        var overflow = false

        for url in urls {
            guard Self.looksLikeImage(url) else {
                rejectedKind = true
                continue
            }
            let standard = url.standardizedFileURL
            guard !photoURLs.contains(where: { $0.standardizedFileURL == standard }) else { continue }
            guard photoURLs.count < PetSubmissionRules.maxPhotos else {
                overflow = true
                continue
            }
            photoURLs.append(url)
            loadThumbnail(for: url)
        }

        if overflow {
            notice = String(localized: "You can send up to \(PetSubmissionRules.maxPhotos) photos — the extras were skipped.")
        } else if rejectedKind {
            notice = String(localized: "Only images can be sent — anything else was skipped.")
        }
    }

    func remove(_ url: URL) {
        photoURLs.removeAll { $0 == url }
        thumbnails.removeValue(forKey: url)
        notice = nil
    }

    private func loadThumbnail(for url: URL) {
        Task.detached(priority: .userInitiated) {
            let image = PetSubmissionThumbnails.image(for: url)
            await MainActor.run { [weak self] in
                guard let self, self.photoURLs.contains(url) else { return }
                self.thumbnails[url] = image
            }
        }
    }

    func retry() {
        phase = .editing
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .webP, .heic, .tiff, .image]
        guard panel.runModal() == .OK else { return }
        addPhotos(panel.urls)
    }

    func submit() async {
        guard canSubmit else { return }
        guard !PetAccess.requiresPaywall(forSubmissionCount: PetSubmissionStore.shared.submissionCount,
                                         state: StoreKitService.shared.state) else {
            notice = String(localized: "WallPics Pro is required to add more pets.")
            return
        }

        let urls = photoURLs
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(PetSubmissionRules.maxNameLength))
        let trimmedNotes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(PetSubmissionRules.maxNotesLength))
        notice = nil
        phase = .uploading

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try urls.map { try PetSubmissionPhotoPrep.prepare(url: $0) }
            }.value

            let digests = prepared.map(\.digest)
            if digests.contains(where: PetSubmissionStore.shared.hasSent) {
                Log.app.notice("Pet submission refused: a photo was already sent")
                notice = PetSubmissionError.alreadySent.errorDescription
                phase = .editing
                return
            }

            let serverID = try await WallpaperAPI.shared.submitPet(
                name: trimmedName.isEmpty ? nil : trimmedName,
                description: trimmedNotes.isEmpty ? nil : trimmedNotes,
                photos: prepared
            )

            let record = PetSubmissionRecord(
                id: UUID(),
                name: trimmedName.isEmpty ? String(localized: "Your pet") : trimmedName,
                submittedAt: Date(),
                photoCount: prepared.count,
                serverPetID: serverID
            )
            if !PetSubmissionStore.shared.add(record, photoDigests: digests) {
                notice = String(localized: "Sent for review, but the entry couldn't be saved to your list.")
            }
            phase = .done(record)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.api.error("Pet submission failed — \(reason, privacy: .private)")
            phase = .failed(reason)
        }
    }

    private static func looksLikeImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }
}
