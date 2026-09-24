import Foundation
import Observation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import UserNotifications

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

private struct PetSubmissionsFile: Codable {
    static let currentVersion = 4
    static let maxRememberedDigests = 200

    var version: Int = currentVersion
    var records: [PetSubmissionRecord] = []
    var submissionCount: Int = 0
    var sentPhotoDigests: [String] = []
    var ownedPetIDs: [Int] = []
    var credits = DIYCreditLedger()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        records = try c.decodeIfPresent([PetSubmissionRecord].self, forKey: .records) ?? []
        submissionCount = try c.decodeIfPresent(Int.self, forKey: .submissionCount) ?? records.count
        sentPhotoDigests = try c.decodeIfPresent([String].self, forKey: .sentPhotoDigests) ?? []
        ownedPetIDs = try c.decodeIfPresent([Int].self, forKey: .ownedPetIDs) ?? records.compactMap(\.serverPetID)
        credits = try c.decodeIfPresent(DIYCreditLedger.self, forKey: .credits) ?? DIYCreditLedger()
    }
}

@MainActor
@Observable
final class PetSubmissionStore {
    static let shared = PetSubmissionStore()
    static let didChange = Notification.Name("PetSubmissionStoreDidChange")

    private(set) var records: [PetSubmissionRecord] = []
    private(set) var submissionCount = 0
    private(set) var ownedPetIDs: Set<Int> = []
    private(set) var ledger = DIYCreditLedger()
    private var sentPhotoDigests: [String] = []

    static var fileURL: URL { PetPaths.root.appendingPathComponent("submissions.json") }

    init() {
        let file = Self.load()
        records = file.records
        submissionCount = file.submissionCount
        sentPhotoDigests = file.sentPhotoDigests
        ownedPetIDs = Set(file.ownedPetIDs)
        ledger = file.credits
    }

    var credits: Int { ledger.credits }

    var unlockedPetIDs: Set<Int> { ownedPetIDs.intersection(RemotePetService.shared.communityIDs.union(readyServerIDs)) }

    @discardableResult
    func grantCredit(transactionID: UInt64) -> Bool {
        let before = ledger
        guard ledger.grant(transactionID: transactionID) else { return true }
        guard persist() else {
            ledger = before
            return false
        }
        Log.store.info("PetSubmissionStore: DIY pet credit added, \(self.ledger.credits) available")
        return true
    }

    @discardableResult
    func revokeCredit(transactionID: UInt64) -> Bool {
        let before = (ledger, records, ownedPetIDs)
        switch ledger.revoke(transactionID: transactionID) {
        case .ignored:
            return true
        case .unspent:
            break
        case .spent(let paidPetID):
            if let paidPetID { ownedPetIDs.remove(paidPetID) }
            if let index = records.firstIndex(where: { $0.creditTransactionID == transactionID }) {
                records[index].creditTransactionID = nil
                if let serverID = records[index].serverPetID { ownedPetIDs.remove(serverID) }
            }
        }
        guard persist() else {
            (ledger, records, ownedPetIDs) = before
            return false
        }
        Log.store.notice("PetSubmissionStore: DIY pet purchase \(transactionID) was refunded, \(self.ledger.credits) credit(s) left")
        return true
    }

    func hasSent(digest: String) -> Bool {
        sentPhotoDigests.contains(digest)
    }

    @discardableResult
    func add(_ record: PetSubmissionRecord, photoDigests: [String]) -> Bool {
        var stored = record
        stored.creditTransactionID = ledger.consume()
        if let transactionID = stored.creditTransactionID, let serverID = record.serverPetID {
            ledger.recordPurchase(transactionID: transactionID, serverPetID: serverID)
        }
        records.removeAll { $0.id == record.id }
        records.insert(stored, at: 0)
        submissionCount += 1
        if let serverID = record.serverPetID { ownedPetIDs.insert(serverID) }
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

    var inReview: [PetSubmissionRecord] { records.filter { $0.status == .inReview } }

    var ready: [PetSubmissionRecord] { records.filter { $0.status == .ready } }

    var unseenReady: [PetSubmissionRecord] { records.filter(\.isUnseenReady) }

    var readyServerIDs: Set<Int> { Set(ready.compactMap(\.serverPetID)) }

    var menuState: PetDIY.MenuState {
        PetDIY.menuState(inReview: inReview.count, unseenReady: unseenReady.count)
    }

    @discardableResult
    func reconcile(approvedServerIDs: Set<Int>) -> [PetSubmissionRecord] {
        var newlyReady: [PetSubmissionRecord] = []
        for index in records.indices where records[index].status == .inReview {
            guard let serverID = records[index].serverPetID, approvedServerIDs.contains(serverID) else { continue }
            records[index].status = .ready
            records[index].rejectionReason = nil
            records[index].readySeen = false
            newlyReady.append(records[index])
        }
        guard !newlyReady.isEmpty else { return [] }
        Log.app.info("PetSubmissionStore: \(newlyReady.count) submission(s) now live in the catalog")
        persist()
        return newlyReady
    }

    func markReadySeen(ids: Set<UUID>? = nil) {
        var changed = false
        for index in records.indices where records[index].isUnseenReady {
            guard ids?.contains(records[index].id) ?? true else { continue }
            records[index].readySeen = true
            changed = true
        }
        guard changed else { return }
        persist()
    }

    func markRejected(serverID: Int, reason: String?) {
        guard let index = records.firstIndex(where: { $0.serverPetID == serverID && $0.status == .inReview }) else { return }
        records[index].status = .rejected
        records[index].rejectionReason = reason
        Log.app.notice("PetSubmissionStore: pet \(serverID) was rejected")
        if let transactionID = records[index].creditTransactionID {
            records[index].creditTransactionID = nil
            ledger.restore(transactionID: transactionID)
            Log.store.info("PetSubmissionStore: DIY pet credit returned after rejection, \(self.ledger.credits) available")
        }
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        defer { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        var file = PetSubmissionsFile()
        file.records = records
        file.submissionCount = submissionCount
        file.sentPhotoDigests = sentPhotoDigests
        file.ownedPetIDs = ownedPetIDs.sorted()
        file.credits = ledger
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
        case purchasing
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

    func reset() {
        guard !isBusy else { return }
        photoURLs = []
        thumbnails = [:]
        name = ""
        notes = ""
        notice = nil
        phase = .editing
    }

    var isBusy: Bool { phase == .uploading || phase == .purchasing }

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

            if PetAccess.submissionNeedsPurchase(credits: PetSubmissionStore.shared.credits) {
                phase = .purchasing
                let outcome = await StoreKitService.shared.purchaseDIYPet()
                switch outcome {
                case .granted:
                    phase = .uploading
                case .cancelled:
                    phase = .editing
                    return
                case .pending:
                    notice = String(localized: "Your purchase is waiting for approval. Send your photos again once it goes through.")
                    phase = .editing
                    return
                case .failed(let message):
                    notice = message
                    phase = .editing
                    return
                }
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
            PetReadyNotifier.requestAuthorizationIfNeeded()
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

@MainActor
@Observable
final class PetSubmissionSync {
    static let shared = PetSubmissionSync()

    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?
    private(set) var lastError: String?

    private static let interval: TimeInterval = 10 * 60
    private static let minimumGap: TimeInterval = 60
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        PetReadyNotifier.install()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { PetSubmissionSync.shared.refreshNow() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers.append(NotificationCenter.default.addObserver(
            forName: RemotePetService.didUpdate, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PetSubmissionSync.shared.reconcileWithCatalog() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PetSubmissionSync.shared.refreshNow() }
        })
        reconcileWithCatalog()
        if !PetSubmissionStore.shared.inReview.isEmpty {
            PetReadyNotifier.requestAuthorizationIfNeeded()
        }
        refreshNow()
    }

    func refreshNow(force: Bool = false) {
        guard inFlight == nil else { return }
        if !force, let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.minimumGap { return }
        let pending = PetSubmissionStore.shared.inReview.compactMap(\.serverPetID)
        guard !pending.isEmpty else {
            lastError = nil
            return
        }
        inFlight = Task { [weak self] in
            await self?.check(pending)
            self?.inFlight = nil
        }
    }

    private func reconcileWithCatalog() {
        let live = Set(RemotePetService.shared.pets.compactMap(\.remoteID))
        PetReadyCenter.shared.announce(PetSubmissionStore.shared.reconcile(approvedServerIDs: live))
    }

    private func check(_ ids: [Int]) async {
        isChecking = true
        defer { isChecking = false }
        var approved: [Int] = []
        var failures = 0
        for id in ids {
            do {
                let body = try await WallpaperAPI.shared.petStatus(id: id)
                switch PetSubmissionOutcome.parse(body) {
                case .approved:
                    approved.append(id)
                case .rejected(let reason):
                    PetSubmissionStore.shared.markRejected(serverID: id, reason: reason)
                case .stillPending:
                    continue
                case .unrecognized(let detail):
                    failures += 1
                    Log.api.error("PetSubmissionSync: unexpected answer for pet \(id) — \(detail, privacy: .public)")
                }
            } catch {
                failures += 1
                Log.api.error("PetSubmissionSync: status check for pet \(id) failed — \(error.localizedDescription, privacy: .public)")
            }
        }
        lastCheckedAt = Date()
        var refreshError: String?
        if !approved.isEmpty {
            await RemotePetService.shared.refresh()
            refreshError = RemotePetService.shared.lastError
            reconcileWithCatalog()
            let live = Set(RemotePetService.shared.pets.compactMap(\.remoteID))
            let missing = approved.filter { !live.contains($0) }
            if !missing.isEmpty {
                Log.api.notice("PetSubmissionSync: \(missing.count) approved pet(s) not in the catalog yet, will retry")
            }
        }
        if failures > 0 {
            lastError = String(localized: "Couldn't check with WallPics right now. We'll try again in a few minutes.")
        } else {
            lastError = refreshError
        }
    }
}

@MainActor
@Observable
final class PetReadyCenter {
    static let shared = PetReadyCenter()
    static let openDIYRequest = Notification.Name("PetReadyCenterOpenDIY")

    private(set) var announcement: PetSubmissionRecord?
    @ObservationIgnored private var queue: [PetSubmissionRecord] = []

    private init() {}

    func announce(_ records: [PetSubmissionRecord]) {
        guard !records.isEmpty else { return }
        let known = Set(queue.map(\.id) + [announcement?.id].compactMap { $0 })
        let fresh = records.filter { !known.contains($0.id) }
        queue.append(contentsOf: fresh)
        if !Self.isAppInFront {
            fresh.forEach(PetReadyNotifier.notify(record:))
        }
        showNextIfIdle()
    }

    static var isAppInFront: Bool {
        NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && !($0 is NSPanel) }
    }

    func dismiss() {
        if let current = announcement {
            PetSubmissionStore.shared.markReadySeen(ids: [current.id])
        }
        announcement = nil
        DispatchQueue.main.async { [weak self] in self?.showNextIfIdle() }
    }

    private func showNextIfIdle() {
        guard announcement == nil, !queue.isEmpty else { return }
        announcement = queue.removeFirst()
    }
}

enum PetReadyNotifier {
    private static let categoryID = "app.wallpics.mac.petReady"
    private static let presenter = Presenter()

    static func install() {
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = presenter }
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let isPetReady = response.notification.request.content.categoryIdentifier == PetReadyNotifier.categoryID
            DispatchQueue.main.async {
                if isPetReady {
                    NotificationCenter.default.post(name: PetReadyCenter.openDIYRequest, object: nil)
                }
                completionHandler()
            }
        }
    }

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    Log.app.error("PetReadyNotifier: authorization failed — \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.app.info("PetReadyNotifier: notifications \(granted ? "allowed" : "declined", privacy: .public)")
                }
            }
        }
    }

    static func notify(record: PetSubmissionRecord) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(record.name) is ready")
        content.body = String(localized: "Your pet is built. Open WallPics to put it on your desktop.")
        content.sound = .default
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(identifier: "petReady-\(record.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("PetReadyNotifier: could not post notification — \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
