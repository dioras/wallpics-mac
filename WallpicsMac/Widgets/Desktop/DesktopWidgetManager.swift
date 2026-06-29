import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class DesktopWidgetManager {
    static let shared = DesktopWidgetManager()
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    static let shadowPad: CGFloat = 22
    static let gridStep: CGFloat = 16

    private(set) var placedIDs: Set<UUID> = []

    private var windows: [UUID: NSWindow] = [:]
    private var placements: [UUID: DesktopWidgetPlacement] = [:]
    private var moveObservers: [UUID: NSObjectProtocol] = [:]
    private var snapWork: [UUID: DispatchWorkItem] = [:]

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
        snapWork[id]?.cancel()
        snapWork[id] = nil
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
        let pad = Self.shadowPad
        let windowFrame = placement.frame.insetBy(dx: -pad, dy: -pad)
        let window = DesktopWidgetWindow(contentRect: windowFrame)
        let root = DesktopWidgetContent(instanceID: id, padding: pad)
            .environment(WidgetStore.shared)
            .environment(DesktopWidgetManager.shared)
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(windowFrame, display: true)

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { self?.windowMoved(window, id: id, pad: pad) }
        }
        moveObservers[id] = token

        window.didEndDrag = { [weak self, weak window] in
            guard let self, let window else { return }
            MainActor.assumeIsolated { self.snapToGrid(window, id: id) }
        }

        window.orderFrontRegardless()
        windows[id] = window
        placedIDs.insert(id)
    }

    private func windowMoved(_ window: NSWindow, id: UUID, pad: CGFloat) {
        if var placement = placements[id] {
            placement.frame = window.frame.insetBy(dx: pad, dy: pad)
            placements[id] = placement
        }
        snapWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.snapWork[id] = nil
            self.snapToGrid(window, id: id)
        }
        snapWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func snapToGrid(_ window: NSWindow, id: UUID) {
        let pad = Self.shadowPad
        let visual = window.frame.insetBy(dx: pad, dy: pad)
        let snapped = Self.snap(rect: visual)
        if abs(snapped.minX - visual.minX) > 0.5 || abs(snapped.minY - visual.minY) > 0.5 {
            window.setFrame(snapped.insetBy(dx: -pad, dy: -pad), display: true, animate: true)
        }
        updateFrame(snapped, for: id)
    }

    private static func snap(rect: CGRect) -> CGRect {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let g = gridStep
        let x = screen.minX + round((rect.minX - screen.minX) / g) * g
        let y = screen.minY + round((rect.minY - screen.minY) / g) * g
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private func defaultPlacement(for instance: WidgetInstance) -> DesktopWidgetPlacement {
        let size = instance.family.desktopSize
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let jitter = CGFloat(placements.count % 6) * 28
        let origin = CGPoint(
            x: screen.midX - size.width / 2 + jitter,
            y: screen.midY - size.height / 2 - jitter
        )
        let rect = Self.snap(rect: CGRect(origin: origin, size: size))
        return DesktopWidgetPlacement(id: instance.id, frame: rect,
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
    var didEndDrag: (() -> Void)?

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

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        didEndDrag?()
    }
}

private struct DesktopWidgetContent: View {
    let instanceID: UUID
    var padding: CGFloat = 0
    @Environment(WidgetStore.self) private var store
    @Environment(DesktopWidgetManager.self) private var desktop

    var body: some View {
        Group {
            if let instance = store.instance(id: instanceID) {
                let interactive = instance.kind.isInteractive
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                let bordered = [WidgetKind.photo, .video, .staticImage, .dateTime].contains(instance.kind)
                WidgetRenderView(instance: instance,
                                 isToggled: Self.flag(for: instance),
                                 carouselStep: desktop.step(for: instanceID))
                    .clipShape(shape)
                    .overlay { if bordered { shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5) } }
                    .contentShape(shape)
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
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                    .padding(padding)
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
