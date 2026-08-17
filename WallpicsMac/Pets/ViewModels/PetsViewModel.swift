import Foundation
import Observation

@MainActor
@Observable
final class PetsViewModel {
    var query: String = ""

    let species: [PetSpecies] = PetCatalog.all
    let store = PetStore.shared
    let desktop = DesktopPetManager.shared

    var filtered: [PetSpecies] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return species }
        return species.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var active: PetSpecies? { store.activeSpecies }

    var isCatalogMissing: Bool { species.isEmpty }

    func place(_ pet: PetSpecies) {
        store.activate(pet)
        desktop.start()
    }

    func removeFromDesktop() {
        store.clear()
        desktop.stop()
    }

    func retry() {
        desktop.stop()
        desktop.start()
    }

    func setSize(_ size: PetSize) {
        store.update { $0.size = size }
        desktop.refresh()
    }

    func setAnchor(_ anchor: PetAnchor) {
        store.update { $0.anchor = anchor }
        desktop.refresh()
    }

    func setAllScreens(_ value: Bool) {
        store.update { $0.allScreens = value }
        desktop.refresh()
    }
}
