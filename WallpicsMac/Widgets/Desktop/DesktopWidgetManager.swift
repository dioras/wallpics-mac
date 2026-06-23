import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class DesktopWidgetManager {
    static let shared = DesktopWidgetManager()
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private(set) var placedIDs: Set<UUID> = []

    private var windows: [UUID: NSWindow] = [:]
    private var placements: [UUID: DesktopWidgetPlacement] = [:]
    private var moveObservers: [UUID: NSObjectProtocol] = [:]

    private init() {
        for p in WidgetPlacementStore.load() { placements[p.id] = p }
    }

    func isPlaced(_ id: UUID) -> Bool { placedIDs.contains(id) }

    func restoreAll() {
        let stale = placements.keys.filter { WidgetStore.shared.instance(id: $0) == nil }
        for id in stale { placements[id] = nil }
        for (id, placement) in placements {
            showWindow(for: id, placement: placement)
        }
        persist()
    }

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
        placedIDs.remove(id)
        if placements[id] != nil {
            placements[id] = nil
            persist()
        }
    }

    func deleteWidget(_ id: UUID) {
        remove(id)
        WidgetStore.shared.delete(id: id)
    }

    func bringToFront(_ id: UUID) {
        for (other, window) in windows where other != id {
            window.level = Self.desktopLevel
        }
        if let window = windows[id] {
            window.level = Self.desktopLevel + 1
            window.orderFrontRegardless()
        }
    }

    func requestEdit(_ id: UUID) {
        AppEnvironment.shared.selectedSection = .widgets
        AppEnvironment.shared.widgetEditRequestID = id
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is DesktopWidgetWindow) }) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    func updateFrame(_ frame: CGRect, for id: UUID) {
        guard var placement = placements[id] else { return }
        placement.frame = frame
        placements[id] = placement
        persist()
    }

    func updateToggle(_ isToggled: Bool, for id: UUID) {
        guard var placement = placements[id] else { return }
        placement.step = isToggled ? 1 : 0
        placements[id] = placement
        WidgetStore.shared.setToggle(id: id, isOn: isToggled)
        persist()
    }

    func advance(for id: UUID) {
        guard var placement = placements[id] else { return }
        placement.step += 1
        placements[id] = placement
        persist()
    }

    func step(for id: UUID) -> Int { placements[id]?.step ?? 0 }

    private func showWindow(for id: UUID, placement: DesktopWidgetPlacement) {
        guard windows[id] == nil else {
            windows[id]?.orderFrontRegardless()
            return
        }
        let window = DesktopWidgetWindow(contentRect: placement.frame)
        let root = DesktopWidgetContent(instanceID: id)
            .environment(WidgetStore.shared)
            .environment(DesktopWidgetManager.shared)
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(placement.frame, display: true)

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
        let jitter = CGFloat(placements.count % 6) * 28
        let origin = CGPoint(
            x: screen.midX - size.width / 2 + jitter,
            y: screen.midY - size.height / 2 - jitter
        )
        return DesktopWidgetPlacement(id: instance.id, frame: CGRect(origin: origin, size: size),
                                      step: Self.initialStep(for: instance))
    }

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

final class DesktopWidgetWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        ignoresMouseEvents = false
        level = DesktopWidgetManager.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

private struct DesktopWidgetContent: View {
    let instanceID: UUID
    @Environment(WidgetStore.self) private var store
    @Environment(DesktopWidgetManager.self) private var desktop

    var body: some View {
        Group {
            if let instance = store.instance(id: instanceID) {
                let interactive = instance.kind.isInteractive
                WidgetRenderView(instance: instance,
                                 isToggled: Self.flag(for: instance),
                                 carouselStep: desktop.step(for: instanceID))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onTapGesture {
                        guard interactive else { return }
                        if instance.kind == .polaroid {
                            desktop.advance(for: instanceID)
                        } else {
                            desktop.updateToggle(!Self.flag(for: instance), for: instanceID)
                        }
                    }
                    .contextMenu {
                        if interactive {
                            Button(actionLabel(for: instance), systemImage: "hand.tap") {
                                if instance.kind == .polaroid {
                                    desktop.advance(for: instanceID)
                                } else {
                                    desktop.updateToggle(!Self.flag(for: instance), for: instanceID)
                                }
                            }
                            Divider()
                        }
                        Button("Edit Widget", systemImage: "pencil") { desktop.requestEdit(instanceID) }
                        Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") { desktop.bringToFront(instanceID) }
                        Divider()
                        Button("Remove from Desktop", systemImage: "rectangle.badge.minus") { desktop.remove(instanceID) }
                        Button("Delete Widget", systemImage: "trash", role: .destructive) { desktop.deleteWidget(instanceID) }
                    }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionLabel(for instance: WidgetInstance) -> String {
        switch instance.kind {
        case .polaroid: return String(localized: "Next Photo")
        case .diyAnimated: return String(localized: "Play")
        default: return Self.flag(for: instance) ? String(localized: "Open") : String(localized: "Close")
        }
    }

    static func flag(for instance: WidgetInstance) -> Bool {
        switch instance.payload {
        case .themed(let s): return s.isClosed
        case .diyAnimated(let s): return s.isOpen
        default: return false
        }
    }
}
