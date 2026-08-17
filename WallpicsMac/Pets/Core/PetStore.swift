import Foundation
import Observation

enum PetPaths {
    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("WallpicsMac", isDirectory: true)
            .appendingPathComponent("Pets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var stateFile: URL { root.appendingPathComponent("pets.json") }
}

@MainActor
@Observable
final class PetStore {
    static let shared = PetStore()

    private(set) var placement: PetPlacement?

    init() {
        placement = Self.loadState().placement
    }

    var activeSpecies: PetSpecies? {
        placement.flatMap { PetCatalog.species(slug: $0.speciesSlug) }
    }

    func isActive(_ slug: String) -> Bool {
        placement?.speciesSlug == slug
    }

    func activate(_ species: PetSpecies) {
        var next = placement ?? PetPlacement(speciesSlug: species.slug)
        next.speciesSlug = species.slug
        placement = next
        persist()
    }

    func clear() {
        placement = nil
        persist()
    }

    func update(_ transform: (inout PetPlacement) -> Void) {
        guard var current = placement else { return }
        transform(&current)
        placement = current
        persist()
    }

    private func persist() {
        let state = PetsState(placement: placement)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: PetPaths.stateFile, options: .atomic)
        } catch {
            Log.app.error("PetStore: failed to save state — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadState() -> PetsState {
        guard let data = try? Data(contentsOf: PetPaths.stateFile) else { return PetsState() }
        do {
            return try JSONDecoder().decode(PetsState.self, from: data)
        } catch {
            let backup = PetPaths.stateFile.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: PetPaths.stateFile, to: backup)
            Log.app.error("PetStore: unreadable state moved aside — \(error.localizedDescription, privacy: .public)")
            return PetsState()
        }
    }
}
