import AppKit
import Observation
import QuartzCore

@MainActor
@Observable
final class DesktopPetManager {
    static let shared = DesktopPetManager()

    enum PauseReason: Hashable {
        case userToggle, lowPower, onBattery, screenSleep
    }

    private(set) var isPaused = false

    var pauseSummary: String? {
        guard isPaused else { return nil }
        if pauseReasons.contains(.userToggle) { return String(localized: "Paused by you") }
        if pauseReasons.contains(.screenSleep) { return String(localized: "Paused while the display sleeps") }
        return String(localized: "Paused")
    }
    private(set) var isRunning = false
    private(set) var loadFailure: String?

    @ObservationIgnored private var windows: [CGDirectDisplayID: DesktopPetWindow] = [:]
    @ObservationIgnored private var renderers: [CGDirectDisplayID: PetRenderer] = [:]
    @ObservationIgnored private var pauseReasons: Set<PauseReason> = []
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var lastTickTime: CFTimeInterval = 0
    @ObservationIgnored private var lastCursor: CGPoint = .zero
    @ObservationIgnored private var settledSince: CFTimeInterval = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private let idleGracePeriod: CFTimeInterval = 1.2

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileScreens() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true, reason: .screenSleep) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setPaused(false, reason: .screenSleep)
                self?.reassertWindows()
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertWindows() }
        })
    }

    func restoreAll() {
        guard let placement = PetStore.shared.placement,
              PetCatalog.species(slug: placement.speciesSlug) != nil else { return }
        start()
    }

    func start() {
        guard let placement = PetStore.shared.placement,
              let species = PetCatalog.species(slug: placement.speciesSlug) else {
            stop()
            return
        }
        isRunning = true
        loadFailure = nil
        rebuildWindows(species: species, placement: placement)
        resumeTicking()
    }

    func stop() {
        isRunning = false
        stopTicking()
        for window in windows.values {
            window.petView.detach()
            window.close()
        }
        windows.removeAll()
        renderers.removeAll()
    }

    func refresh() {
        guard isRunning else { return }
        start()
    }

    func setPaused(_ paused: Bool, reason: PauseReason) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let next = !pauseReasons.isEmpty
        guard next != isPaused else { return }
        isPaused = next
        if isPaused {
            stopTicking()
        } else if isRunning {
            resumeTicking()
        }
    }

    func toggleUserPause() {
        setPaused(!pauseReasons.contains(.userToggle), reason: .userToggle)
    }

    private func targetScreens(_ placement: PetPlacement) -> [NSScreen] {
        if placement.allScreens { return NSScreen.screens }
        guard let primary = NSScreen.screens.first else {
            Log.app.error("DesktopPetManager: no screens available")
            return []
        }
        return [primary]
    }

    private func rebuildWindows(species: PetSpecies, placement: PetPlacement) {
        let screens = targetScreens(placement)
        var wanted: Set<CGDirectDisplayID> = []

        for screen in screens {
            guard let id = screen.displayID else {
                Log.app.error("DesktopPetManager: screen without a display id, skipping")
                continue
            }
            wanted.insert(id)
            let window: DesktopPetWindow
            if let existing = windows[id] {
                window = existing
                window.setFrame(screen.frame, display: false)
            } else {
                window = DesktopPetWindow(screen: screen, screenID: id)
                windows[id] = window
            }
            let renderer: PetRenderer
            if let existing = renderers[id], existing.species.slug == species.slug {
                renderer = existing
            } else {
                renderer = PetRenderer(species: species)
                renderer.onLoadFailure = { [weak self] message in
                    MainActor.assumeIsolated { self?.loadFailure = message }
                }
                renderers[id] = renderer
                window.petView.attach(renderer)
            }
            window.petView.place(localRect(species: species, placement: placement, screen: screen),
                                 scale: screen.backingScaleFactor)
            window.orderFrontRegardless()
        }

        for (id, window) in windows where !wanted.contains(id) {
            window.petView.detach()
            window.close()
            windows.removeValue(forKey: id)
            renderers.removeValue(forKey: id)
        }
    }

    func petFrame(species: PetSpecies, placement: PetPlacement, screen: NSScreen) -> CGRect {
        globalRect(species: species, placement: placement, screen: screen)
    }

    private func globalRect(species: PetSpecies, placement: PetPlacement, screen: NSScreen) -> CGRect {
        let frameHeight = placement.size.pointHeight / species.subjectHeight
        let size = CGSize(width: frameHeight * species.aspectRatio, height: frameHeight)
        var rect = placement.anchor.rect(for: size, in: screen.frame, margin: 28)
        rect.origin.y -= (1 - species.subjectBottom) * frameHeight
        return rect
    }

    private func localRect(species: PetSpecies, placement: PetPlacement, screen: NSScreen) -> CGRect {
        globalRect(species: species, placement: placement, screen: screen)
            .offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func reconcileScreens() {
        guard isRunning else { return }
        stopTicking()
        start()
    }

    func reassertAboveBackdrop() {
        for window in windows.values {
            window.level = DesktopPetWindow.behindIconsLevel
            window.orderFrontRegardless()
        }
    }

    private func reassertWindows() {
        for window in windows.values {
            window.level = DesktopPetWindow.behindIconsLevel
            window.orderFrontRegardless()
        }
    }

    private func resumeTicking() {
        guard displayLink == nil, !isPaused, isRunning else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let link = screen?.displayLink(target: self, selector: #selector(handleTick)) else {
            Log.app.error("DesktopPetManager: could not create a display link for the pet")
            return
        }
        idleTimer?.invalidate()
        idleTimer = nil
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTickTime = CACurrentMediaTime()
        settledSince = 0
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func enterIdle() {
        displayLink?.invalidate()
        displayLink = nil
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let cursor = NSEvent.mouseLocation
                guard hypot(cursor.x - self.lastCursor.x, cursor.y - self.lastCursor.y) > 1.5 else { return }
                self.resumeTicking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    @objc private func handleTick() {
        guard isRunning, !isPaused,
              let placement = PetStore.shared.placement,
              let species = PetCatalog.species(slug: placement.speciesSlug) else { return }

        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTickTime, 1.0 / 240.0), 1.0 / 15.0)
        lastTickTime = now

        let cursor = NSEvent.mouseLocation
        let cursorMoved = hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) > 0.5
        lastCursor = cursor

        var moving = false
        for (id, window) in windows {
            guard let renderer = renderers[id], let screen = window.screen ?? NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            let rect = globalRect(species: species, placement: placement, screen: screen)
            moving = renderer.tick(dt: dt, cursor: cursor, petRect: rect,
                                   sensitivity: placement.sensitivity) || moving
        }

        if moving || cursorMoved {
            settledSince = 0
        } else {
            if settledSince == 0 { settledSince = now }
            if now - settledSince > idleGracePeriod { enterIdle() }
        }
    }
}
