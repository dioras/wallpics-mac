import Foundation
import Observation

@MainActor
@Observable
final class PetsViewModel {
    var query: String = ""

    private(set) var species: [PetSpecies] = PetCatalog.all
    @ObservationIgnored private var remoteObserver: NSObjectProtocol?

    init() {
        remoteObserver = NotificationCenter.default.addObserver(
            forName: RemotePetService.didUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.species = PetCatalog.all
                let remoteIDs = Set(RemotePetService.shared.pets.compactMap { $0.remoteID })
                self.submissions.reconcile(approvedServerIDs: remoteIDs)
            }
        }
        Task { await RemotePetService.shared.refresh() }
    }

    deinit {
        if let remoteObserver {
            NotificationCenter.default.removeObserver(remoteObserver)
        }
    }

    let store = PetStore.shared
    let desktop = DesktopPetManager.shared
    let profiles = PetProfileStore.shared
    let backdrop = PetBackdropService.shared
    let submissions = PetSubmissionStore.shared

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
        if let placement = store.placement, placement.showsProfileBackdrop {
            backdrop.apply(species: pet, placement: placement)
        }
    }

    func removeFromDesktop() {
        backdrop.clear()
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

    func setSensitivity(_ value: PetSensitivity) {
        store.update { $0.sensitivity = value }
    }

    func setProfileBackdrop(_ enabled: Bool) {
        store.update { $0.showsProfileBackdrop = enabled }
        guard let placement = store.placement, let species = active else { return }
        if enabled {
            backdrop.apply(species: species, placement: placement)
        } else {
            backdrop.clear()
        }
    }

    func profile(for species: PetSpecies) -> PetProfile { profiles.profile(for: species) }

    func updateProfile(_ profile: PetProfile, for species: PetSpecies) {
        profiles.update(profile, for: species)
        if store.placement?.showsProfileBackdrop == true, let placement = store.placement {
            backdrop.apply(species: species, placement: placement)
        }
    }

    var guardianName: String { profiles.guardianName }
}
