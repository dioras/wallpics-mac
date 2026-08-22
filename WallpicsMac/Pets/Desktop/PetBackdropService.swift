import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PetBackdropService {
    static let shared = PetBackdropService()

    private(set) var isApplied = false
    private(set) var lastError: String?

    @ObservationIgnored private var windows: [CGDirectDisplayID: PetBackdropWindow] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let legacyRestoreKey = "PetBackdropRestorePoints"

    init() {
        undoLegacyWallpaperOverride()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isApplied else { return }
                self.reapply()
            }
        }
    }

    func apply(species: PetSpecies, placement: PetPlacement) {
        let profile = PetProfileStore.shared.profile(for: species)
        let guardian = PetProfileStore.shared.guardianName
        var wanted: Set<CGDirectDisplayID> = []

        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            wanted.insert(id)
            let frame = DesktopPetManager.shared.petFrame(species: species, placement: placement,
                                                          screen: screen)
            let local = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            let image = PetBackdropRenderer.image(size: screen.frame.size, species: species,
                                                  profile: profile, guardian: guardian,
                                                  petFrame: local)
            let window: PetBackdropWindow
            if let existing = windows[id] {
                window = existing
                window.setFrame(screen.frame, display: false)
            } else {
                window = PetBackdropWindow(screen: screen, screenID: id)
                windows[id] = window
            }
            window.update(image: image)
            window.orderFrontRegardless()
        }

        for (id, window) in windows where !wanted.contains(id) {
            window.orderOut(nil)
            window.close()
            windows.removeValue(forKey: id)
        }

        isApplied = !windows.isEmpty
        lastError = windows.isEmpty ? String(localized: "No display available for the backdrop") : nil
        DesktopPetManager.shared.reassertAboveBackdrop()
    }

    func reapply() {
        guard let placement = PetStore.shared.placement,
              let species = PetCatalog.species(slug: placement.speciesSlug),
              placement.showsProfileBackdrop else { return }
        apply(species: species, placement: placement)
    }

    func clear() {
        for window in windows.values {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        isApplied = false
        lastError = nil
    }

    private func undoLegacyWallpaperOverride() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: Self.legacyRestoreKey) as? [String: String] else { return }
        let workspace = NSWorkspace.shared
        for screen in NSScreen.screens {
            guard let key = screen.displayID.map(String.init),
                  let raw = stored[key], let url = URL(string: raw) else { continue }
            try? workspace.setDesktopImageURL(url, for: screen, options: [:])
        }
        defaults.removeObject(forKey: Self.legacyRestoreKey)
    }
}
