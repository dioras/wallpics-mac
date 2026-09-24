import Foundation
import Observation

@MainActor
@Observable
final class PetsViewModel {
    var query: String = ""

    private(set) var species: [PetSpecies] = PetCatalog.all
    @ObservationIgnored private var remoteObserver: NSObjectProtocol?
    @ObservationIgnored private var backdropRedraw: Task<Void, Never>?

    init() {
        remoteObserver = NotificationCenter.default.addObserver(
            forName: RemotePetService.didUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.species = PetCatalog.all
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
    let submissionSync = PetSubmissionSync.shared
    let submission = PetSubmissionModel()

    var scope: PetScope = .all

    var diyIDs: Set<Int> {
        RemotePetService.shared.communityIDs.union(submissions.readyServerIDs)
    }

    var hasDIYPets: Bool {
        species.contains { PetDIY.isDIY(remoteID: $0.remoteID, community: RemotePetService.shared.communityIDs,
                                         own: submissions.readyServerIDs) }
    }

    var ownReadySpecies: [PetSpecies] {
        submissions.ready.compactMap { $0.catalogSlug.flatMap(PetCatalog.species(slug:)) }
    }

    var filtered: [PetSpecies] {
        let community = RemotePetService.shared.communityIDs
        let own = submissions.readyServerIDs
        let scoped = scope == .all
            ? species
            : species.filter { PetDIY.isDIY(remoteID: $0.remoteID, community: community, own: own) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scoped }
        return scoped.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var active: PetSpecies? { store.activeSpecies }

    var selectedSlug: String?

    var focused: PetSpecies? {
        if let slug = selectedSlug, !store.isActive(slug), let pet = species.first(where: { $0.slug == slug }) {
            return pet
        }
        return active
    }

    func select(_ pet: PetSpecies) {
        selectedSlug = store.isActive(pet.slug) ? nil : pet.slug
    }

    func clearSelection() {
        selectedSlug = nil
    }

    var isCatalogMissing: Bool { species.isEmpty }

    func place(_ pet: PetSpecies) {
        if PetDesktopActions.place(pet) {
            selectedSlug = nil
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
        backdrop.reapply()
    }

    func setAnchor(_ anchor: PetAnchor) {
        store.update { $0.anchor = anchor }
        desktop.refresh()
        backdrop.reapply()
    }

    func setAllScreens(_ value: Bool) {
        store.update { $0.allScreens = value }
        desktop.refresh()
        backdrop.reapply()
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

    func displayName(for species: PetSpecies) -> String { profiles.displayName(for: species) }

    func updateProfile(_ profile: PetProfile, for species: PetSpecies) {
        profiles.update(profile, for: species)
        guard store.placement?.showsProfileBackdrop == true else { return }
        backdropRedraw?.cancel()
        backdropRedraw = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled,
                  let placement = PetStore.shared.placement,
                  placement.showsProfileBackdrop,
                  placement.speciesSlug == species.slug else { return }
            PetBackdropService.shared.apply(species: species, placement: placement)
        }
    }

    var guardianName: String { profiles.guardianName }
}

enum PetScope: String, CaseIterable, Identifiable {
    case all, diy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "All pets")
        case .diy: return String(localized: "DIY")
        }
    }
}

@MainActor
enum PetDesktopActions {
    @discardableResult
    static func place(_ pet: PetSpecies) -> Bool {
        guard !PetAccess.requiresPaywall(pet: pet, state: StoreKitService.shared.state,
                                        ownedIDs: PetSubmissionStore.shared.unlockedPetIDs) else {
            PaywallPresenter.show()
            return false
        }
        PetStore.shared.activate(pet)
        DesktopPetManager.shared.start()
        if let placement = PetStore.shared.placement, placement.showsProfileBackdrop {
            PetBackdropService.shared.apply(species: pet, placement: placement)
        }
        return true
    }
}
