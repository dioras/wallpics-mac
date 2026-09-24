import CryptoKit
import Foundation

struct PetSubmissionPhoto: Sendable {
    let fileName: String
    let data: Data

    var digest: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PetSubmissionRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let submittedAt: Date
    let photoCount: Int
    let serverPetID: Int?
    var status: PetSubmissionStatus = .inReview
    var rejectionReason: String?
    var readySeen: Bool = false
    var creditTransactionID: UInt64?

    init(id: UUID, name: String, submittedAt: Date, photoCount: Int, serverPetID: Int?,
         status: PetSubmissionStatus = .inReview, rejectionReason: String? = nil, readySeen: Bool = false,
         creditTransactionID: UInt64? = nil) {
        self.id = id
        self.name = name
        self.submittedAt = submittedAt
        self.photoCount = photoCount
        self.serverPetID = serverPetID
        self.status = status
        self.rejectionReason = rejectionReason
        self.readySeen = readySeen
        self.creditTransactionID = creditTransactionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        submittedAt = try c.decode(Date.self, forKey: .submittedAt)
        photoCount = try c.decode(Int.self, forKey: .photoCount)
        serverPetID = try c.decodeIfPresent(Int.self, forKey: .serverPetID)
        status = (try? c.decodeIfPresent(PetSubmissionStatus.self, forKey: .status)) ?? .inReview
        rejectionReason = try c.decodeIfPresent(String.self, forKey: .rejectionReason)
        readySeen = try c.decodeIfPresent(Bool.self, forKey: .readySeen) ?? true
        creditTransactionID = try c.decodeIfPresent(UInt64.self, forKey: .creditTransactionID)
    }

    var catalogSlug: String? { serverPetID.map(PetSpecies.remoteSlug(id:)) }

    var isUnseenReady: Bool { status == .ready && !readySeen }

    func isOverdue(now: Date = Date()) -> Bool {
        status == .inReview && (serverPetID == nil || PetSubmissionAge.isStale(submittedAt: submittedAt, now: now))
    }
}

struct DIYCreditLedger: Codable, Equatable, Sendable {
    static let maxRememberedTransactions = 100

    enum Revocation: Equatable, Sendable {
        case ignored
        case unspent
        case spent(serverPetID: Int?)
    }

    private(set) var unspent: [UInt64] = []
    private(set) var grantedTransactions: [UInt64] = []
    private(set) var revokedTransactions: [UInt64] = []
    private(set) var paidPets: [UInt64: Int] = [:]

    var credits: Int { unspent.count }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unspent = try c.decodeIfPresent([UInt64].self, forKey: .unspent) ?? []
        grantedTransactions = try c.decodeIfPresent([UInt64].self, forKey: .grantedTransactions) ?? []
        revokedTransactions = try c.decodeIfPresent([UInt64].self, forKey: .revokedTransactions) ?? []
        paidPets = try c.decodeIfPresent([UInt64: Int].self, forKey: .paidPets) ?? [:]
    }

    mutating func grant(transactionID: UInt64) -> Bool {
        guard !grantedTransactions.contains(transactionID) else { return false }
        unspent.append(transactionID)
        Self.remember(transactionID, in: &grantedTransactions)
        paidPets = paidPets.filter { grantedTransactions.contains($0.key) }
        return true
    }

    mutating func recordPurchase(transactionID: UInt64, serverPetID: Int) {
        guard grantedTransactions.contains(transactionID) else { return }
        paidPets[transactionID] = serverPetID
    }

    mutating func consume() -> UInt64? {
        guard !unspent.isEmpty else { return nil }
        return unspent.removeFirst()
    }

    mutating func restore(transactionID: UInt64) {
        guard !revokedTransactions.contains(transactionID), !unspent.contains(transactionID) else { return }
        paidPets[transactionID] = nil
        unspent.append(transactionID)
    }

    mutating func revoke(transactionID: UInt64) -> Revocation {
        guard grantedTransactions.contains(transactionID),
              !revokedTransactions.contains(transactionID) else { return .ignored }
        Self.remember(transactionID, in: &revokedTransactions)
        guard let index = unspent.firstIndex(of: transactionID) else {
            return .spent(serverPetID: paidPets.removeValue(forKey: transactionID))
        }
        unspent.remove(at: index)
        return .unspent
    }

    private static func remember(_ id: UInt64, in list: inout [UInt64]) {
        list.append(id)
        if list.count > maxRememberedTransactions {
            list.removeFirst(list.count - maxRememberedTransactions)
        }
    }
}

enum PetDIY {
    static let communityCategoryID = 3832

    enum MenuState: Equatable, Sendable {
        case idle
        case waiting(Int)
        case ready(Int)
    }

    static func isDIY(remoteID: Int?, community: Set<Int>, own: Set<Int>) -> Bool {
        guard let remoteID else { return false }
        return community.contains(remoteID) || own.contains(remoteID)
    }

    static func shouldRetryWithoutCategory(statusCode: Int, message: String?) -> Bool {
        guard statusCode == 422, let message else { return false }
        return message.localizedCaseInsensitiveContains("categor")
    }

    static func menuState(inReview: Int, unseenReady: Int) -> MenuState {
        if unseenReady > 0 { return .ready(unseenReady) }
        if inReview > 0 { return .waiting(inReview) }
        return .idle
    }

    static func multipart(boundary: String, name: String?, description: String?,
                          categoryIDs: [Int], photos: [PetSubmissionPhoto]) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ key: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        if let name, !name.isEmpty { field("name", name) }
        if let description, !description.isEmpty { field("description", description) }
        for id in categoryIDs { field("category_ids[]", String(id)) }
        for photo in photos {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"photos[]\"; filename=\"\(photo.fileName)\"\r\n")
            append("Content-Type: image/jpeg\r\n\r\n")
            body.append(photo.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
