import AppKit
import SwiftUI
import Observation

/// Places created widgets on the desktop as live, draggable, clickable overlay windows — the
/// macOS analog of dropping a widget on an iPhone home screen. Each overlay sits just above the
/// desktop icons (so it reads as "on the wallpaper"), shows on every Space, and persists its
/// position + interactive state across relaunch.
///
/// Interactivity that a real macOS WidgetKit extension can't do — the elevator doors opening, the
/// eyelids sliding — works here because we host the widget's SwiftUI ourselves and re-render on a
/// real click.
@MainActor
@Observable
final class DesktopWidgetManager {
    static let shared = DesktopWidgetManager()

    /// Instance ids currently placed on the desktop.
    private(set) var placedIDs: Set<UUID> = []

    private var windows: [UUID: NSWindow] = [:]
    private var placements: [UUID: DesktopWidgetPlacement] = [:]
    private var moveObservers: [UUID: NSObjectProtocol] = [:]

    private init() {
        for p in WidgetPlacementStore.load() { placements[p.id] = p }
    }

    func isPlaced(_ id: UUID) -> Bool { placedIDs.contains(id) }

    /// Recreate overlays for everything that was placed before the last quit. Call once at launch
    /// after the store has loaded.
    func restoreAll() {
        for (id, placement) in placements {
            guard WidgetStore.shared.instance(id: id) != nil else {
                placements[id] = nil          // instance was deleted; drop the stale placement
                continue
            }
            showWindow(for: id, placement: placement)
        }
        persist()
    }

    /// Place (or re-focus) a widget on the desktop.
    func place(_ instance: WidgetInstance) {
        if let existing = windows[instance.id] {
            existing.orderFrontRegardless()
            return
        }
        let placement = placements[instance.id] ?? defaultPlacement(for: instance)
        placements[instance.id] = placement
        showWindow(for: instance.id, placement: placement)
        persist()
    }

    func remove(_ id: UUID) {
        if let token = moveObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
        windows[id]?.close()
        windows[id] = nil
        placements[id] = nil
        placedIDs.remove(id)
        persist()
    }

    /// Persist a moved/resized frame for an instance.
    func updateFrame(_ frame: CGRect, for id: UUID) {
        guard var placement = placements[id] else { return }
        placement.frame = frame
        placements[id] = placement
        persist()
    }

    /// Toggle a themed / DIY widget's flag (payload is the source of truth; the placement mirrors
    /// it as a 0/1 step so a relaunch restores the pose).
    func updateToggle(_ isToggled: Bool, for id: UUID) {
        guard var placement = placements[id] else { return }
        placement.step = isToggled ? 1 : 0
        placements[id] = placement
        WidgetStore.shared.setToggle(id: id, isOn: isToggled)
        persist()
    }

    /// Advance a polaroid carousel by one card and persist the new position.
    func advance(for id: UUID) {
        guard var placement = placements[id] else { return }
        placement.step += 1
        placements[id] = placement
        persist()
    }

    /// Current interaction step for an instance. Reading `placements` here registers an
    /// Observation dependency, so a click (which mutates it) re-renders the overlay.
    func step(for id: UUID) -> Int { placements[id]?.step ?? 0 }

    // MARK: - Window lifecycle

    private func showWindow(for id: UUID, placement: DesktopWidgetPlacement) {
        let window = DesktopWidgetWindow(contentRect: placement.frame)
        let content = DesktopWidgetContent(instanceID: id)
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(placement.frame, display: true)

        // Persist position whenever the user drags the window. `queue: .main` guarantees the
        // closure runs on the main thread, so assuming main-actor isolation is safe. The returned
        // token is retained so it can be torn down in `remove(_:)` — the block-based observer is
        // not auto-removed when its `object` deallocates.
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { self?.updateFrame(window.frame, for: id) }
        }
        moveObservers[id] = token

        window.orderFrontRegardless()
        windows[id] = window
        placedIDs.insert(id)
    }

    private func defaultPlacement(for instance: WidgetInstance) -> DesktopWidgetPlacement {
        let size = instance.family.desktopSize
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Stagger new widgets a little so they don't stack exactly on top of each other.
        let jitter = CGFloat(placements.count % 6) * 28
        let origin = CGPoint(
            x: screen.midX - size.width / 2 + jitter,
            y: screen.midY - size.height / 2 - jitter
        )
        return DesktopWidgetPlacement(id: instance.id, frame: CGRect(origin: origin, size: size),
                                      step: Self.initialStep(for: instance))
    }

    /// Initial interaction step for a freshly placed widget — themed/DIY start from their payload
    /// flag, everything else from 0.
    private static func initialStep(for instance: WidgetInstance) -> Int {
        switch instance.payload {
        case .themed(let s): return s.isClosed ? 1 : 0
        case .diyAnimated(let s): return s.isOpen ? 1 : 0
        default: return 0
        }
    }

    private func persist() {
        WidgetPlacementStore.save(Array(placements.values))
    }
}

// MARK: - Overlay window

/// Borderless, transparent, draggable window that lives on the desktop layer (just above the
/// icons) on every Space.
final class DesktopWidgetWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true     // drag anywhere to reposition
        ignoresMouseEvents = false
        // Sit just above the desktop icons so the widget reads as part of the wallpaper but stays
        // below regular app windows (the same place macOS keeps its own desktop widgets).
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    // A borderless window won't become key by default; allow it so clicks register for interactive
    // widgets without stealing focus aggressively.
    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay content

/// SwiftUI content for a placed widget. Reads its instance live from `WidgetStore` — the instance
/// payload is the single source of truth for the interactive flag, so an edit-and-save reflects
/// immediately and never diverges from a separate local copy. A click flips the flag through the
/// manager, which persists it back onto the instance.
private struct DesktopWidgetContent: View {
    let instanceID: UUID

    var body: some View {
        Group {
            if let instance = WidgetStore.shared.instance(id: instanceID) {
                WidgetRenderView(instance: instance,
                                 isToggled: Self.flag(for: instance),
                                 carouselStep: DesktopWidgetManager.shared.step(for: instanceID))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard instance.kind.isInteractive else { return }
                        if instance.kind == .polaroid {
                            DesktopWidgetManager.shared.advance(for: instanceID)
                        } else {
                            DesktopWidgetManager.shared.updateToggle(!Self.flag(for: instance), for: instanceID)
                        }
                    }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The persisted interactive flag for an instance (themed closed/hidden, DIY animating).
    static func flag(for instance: WidgetInstance) -> Bool {
        switch instance.payload {
        case .themed(let s): return s.isClosed
        case .diyAnimated(let s): return s.isOpen
        default: return false
        }
    }
}
