import AppKit
import Foundation
import Observation

struct PetProfile: Codable, Equatable, Sendable {
    var displayName: String
    var breed: String
    var gender: String
    var likes: String
    var dislikes: String
    var notes: String

    static let empty = PetProfile(displayName: "", breed: "", gender: "",
                                  likes: "", dislikes: "", notes: "")
}

enum PetProfileDefaults {
    static let table: [String: PetProfile] = [
        "ginger": PetProfile(
            displayName: "Biscuit",
            breed: "European Shorthair",
            gender: "♀",
            likes: "sunny windowsills, warm laps",
            dislikes: "closed doors, the vacuum",
            notes: "Found under a parked car at six weeks old and has been unbothered ever since. "
                 + "Watches the cursor the way other cats watch birds."),
        "dog": PetProfile(
            displayName: "Rusty",
            breed: "Golden Retriever",
            gender: "♂",
            likes: "tennis balls, being told he is good",
            dislikes: "being left out of anything",
            notes: "Retired from carrying sticks, now supervises desk work full time. "
                 + "Tilts his head at every notification and expects an explanation."),
        "leopard": PetProfile(
            displayName: "Kesi",
            breed: "African Leopard",
            gender: "♀",
            likes: "high shelves, long silences",
            dislikes: "small talk, sudden meetings",
            notes: "Keeps her own hours and answers to no calendar. "
                 + "Will hold eye contact until you finish the sentence you started.")
    ]

    static func profile(for slug: String, fallbackName: String) -> PetProfile {
        table[slug] ?? PetProfile(displayName: fallbackName, breed: fallbackName,
                                  gender: "—", likes: "—", dislikes: "—",
                                  notes: "No notes yet. Add a few and they will show up here.")
    }
}

@MainActor
@Observable
final class PetProfileStore {
    static let shared = PetProfileStore()

    private var profiles: [String: PetProfile]

    private static var file: URL { PetPaths.root.appendingPathComponent("profiles.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let decoded = try? JSONDecoder().decode([String: PetProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = [:]
        }
    }

    var guardianName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    func profile(for species: PetSpecies) -> PetProfile {
        profiles[species.slug] ?? PetProfileDefaults.profile(for: species.slug, fallbackName: species.name)
    }

    func update(_ profile: PetProfile, for species: PetSpecies) {
        profiles[species.slug] = profile
        persist()
    }

    func reset(_ species: PetSpecies) {
        profiles.removeValue(forKey: species.slug)
        persist()
    }

    private func persist() {
        do {
            try JSONEncoder().encode(profiles).write(to: Self.file, options: .atomic)
        } catch {
            Log.app.error("PetProfileStore: save failed — \(error.localizedDescription, privacy: .public)")
        }
    }
}
