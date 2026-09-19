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
    static func placeholder(named name: String) -> PetProfile {
        PetProfile(displayName: name, breed: name,
                   gender: "—", likes: "—", dislikes: "—",
                   notes: "No notes yet. Add a few and they will show up here.")
    }
}

@MainActor
@Observable
final class PetProfileStore {
    static let shared = PetProfileStore()

    private var profiles: [String: PetProfile]
    private(set) var lastSaveError: String?

    private static var file: URL { PetPaths.root.appendingPathComponent("profiles.json") }

    init() {
        profiles = Self.loadProfiles()
    }

    private static func loadProfiles() -> [String: PetProfile] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        do {
            return try JSONDecoder().decode([String: PetProfile].self, from: data)
        } catch {
            let backup = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
            Log.app.error("PetProfileStore: unreadable profiles moved aside — \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    var guardianName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    func profile(for species: PetSpecies) -> PetProfile {
        profiles[species.slug] ?? PetProfileDefaults.placeholder(named: species.name)
    }

    func displayName(for species: PetSpecies) -> String {
        let chosen = profile(for: species).displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let untouched = PetProfileDefaults.placeholder(named: species.name).displayName
        return chosen.isEmpty || chosen == untouched ? species.name : chosen
    }

    func update(_ profile: PetProfile, for species: PetSpecies) {
        if profile == PetProfileDefaults.placeholder(named: species.name) {
            guard profiles.removeValue(forKey: species.slug) != nil else { return }
        } else {
            profiles[species.slug] = profile
        }
        persist()
    }

    func clearSaveError() {
        lastSaveError = nil
    }

    func reset(_ species: PetSpecies) {
        profiles.removeValue(forKey: species.slug)
        persist()
    }

    private func persist() {
        do {
            try JSONEncoder().encode(profiles).write(to: Self.file, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = String(localized: "Could not save these details — they will be lost when WallPics quits.")
            Log.app.error("PetProfileStore: save failed at \(Self.file.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }
}
