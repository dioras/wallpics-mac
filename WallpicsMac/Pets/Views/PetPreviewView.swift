import AppKit
import QuartzCore
import SwiftUI

struct PetPreviewView: NSViewRepresentable {
    let species: PetSpecies
    var sensitivity: PetSensitivity = .normal
    var interactive: Bool = false

    func makeNSView(context: Context) -> PetPreviewNSView {
        let view = PetPreviewNSView()
        view.sensitivity = sensitivity
        view.interactive = interactive
        view.configure(species: species)
        return view
    }

    func updateNSView(_ nsView: PetPreviewNSView, context: Context) {
        nsView.sensitivity = sensitivity
        nsView.interactive = interactive
        nsView.configure(species: species)
    }

    static func dismantleNSView(_ nsView: PetPreviewNSView, coordinator: ()) {
        nsView.teardown()
    }
}

final class PetPreviewNSView: NSView {
    private var renderer: PetRenderer?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var currentSpecies: PetSpecies?
    private var observer: NSObjectProtocol?
    private var stroke: PettingStroke?
    private static let strokeLength: CGFloat = 28
    private static let transitionDelay: Double = 2
    var sensitivity: PetSensitivity = .normal
    var interactive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(species: PetSpecies) {
        guard currentSpecies != species else { return }
        currentSpecies = species
        renderer?.layer.removeFromSuperlayer()
        let renderer = PetRenderer(species: species, allowsTransitions: interactive,
                                   transitionDelay: Self.transitionDelay)
        self.renderer = renderer
        layer?.addSublayer(renderer.layer)
        renderer.load()
        layoutPet()
    }

    func teardown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        displayLink?.invalidate()
        displayLink = nil
        renderer?.layer.removeFromSuperlayer()
        renderer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startLink() }
        }
        startLink()
    }

    override func layout() {
        super.layout()
        layoutPet()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { interactive }

    override var mouseDownCanMoveWindow: Bool { !interactive }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        stroke = nil
        guard interactive, let renderer, renderer.canPet, let zone = faceZone() else { return }
        let point = NSEvent.mouseLocation
        guard hypot(point.x - zone.center.x, point.y - zone.center.y) <= zone.radius else { return }
        stroke = PettingStroke(at: point, threshold: Self.strokeLength)
        startLink()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = stroke, let zone = faceZone() else { return }
        let point = NSEvent.mouseLocation
        guard hypot(point.x - zone.center.x, point.y - zone.center.y) <= zone.radius * PettingStroke.slack else {
            stroke = nil
            return
        }
        if current.move(to: point) {
            stroke = nil
            renderer?.pet()
            startLink()
        } else {
            stroke = current
        }
    }

    override func mouseUp(with event: NSEvent) {
        stroke = nil
    }

    private func faceZone() -> (center: CGPoint, radius: CGFloat)? {
        guard let renderer, let window else { return nil }
        let rect = window.convertToScreen(convert(renderer.layer.frame, to: nil))
        return GazeMap.faceZone(petRect: rect, faceCenter: renderer.species.faceCenter,
                                subjectHeight: renderer.species.subjectHeight)
    }

    private func layoutPet() {
        guard let renderer else { return }
        let species = renderer.species
        let aspect = species.aspectRatio
        var height = bounds.height
        var width = height * aspect
        if width > bounds.width {
            width = bounds.width
            height = width / max(aspect, 0.01)
        }
        let rect = CGRect(x: (bounds.width - width) / 2,
                          y: 0,
                          width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = rect
        renderer.layer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    private func startLink() {
        guard displayLink == nil, let window, window.isVisible,
              window.occlusionState.contains(.visible),
              let screen = window.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = CACurrentMediaTime()
    }

    @objc private func tick() {
        guard let renderer, let window else { return }
        guard window.isVisible, window.occlusionState.contains(.visible) else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240.0), 1.0 / 15.0)
        lastTick = now
        let localRect = renderer.layer.frame
        let inWindow = convert(localRect, to: nil)
        let global = window.convertToScreen(inWindow)
        renderer.tick(dt: dt, cursor: NSEvent.mouseLocation, petRect: global, sensitivity: sensitivity)
    }
}
