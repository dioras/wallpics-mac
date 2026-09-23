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

    init(id: UUID, name: String, submittedAt: Date, photoCount: Int, serverPetID: Int?,
         status: PetSubmissionStatus = .inReview, rejectionReason: String? = nil, readySeen: Bool = false) {
        self.id = id
        self.name = name
        self.submittedAt = submittedAt
        self.photoCount = photoCount
        self.serverPetID = serverPetID
        self.status = status
        self.rejectionReason = rejectionReason
        self.readySeen = readySeen
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
    }

    var catalogSlug: String? { serverPetID.map(PetSpecies.remoteSlug(id:)) }

    var isUnseenReady: Bool { status == .ready && !readySeen }

    func isOverdue(now: Date = Date()) -> Bool {
        status == .inReview && (serverPetID == nil || PetSubmissionAge.isStale(submittedAt: submittedAt, now: now))
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
