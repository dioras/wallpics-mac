import AppKit
import QuartzCore
import SwiftUI

struct PetPreviewView: NSViewRepresentable {
    let species: PetSpecies

    func makeNSView(context: Context) -> PetPreviewNSView {
        let view = PetPreviewNSView()
        view.configure(species: species)
        return view
    }

    func updateNSView(_ nsView: PetPreviewNSView, context: Context) {
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
    private var currentSlug: String?
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(species: PetSpecies) {
        guard currentSlug != species.slug else { return }
        currentSlug = species.slug
        renderer?.layer.removeFromSuperlayer()
        let renderer = PetRenderer(species: species)
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

    private func layoutPet() {
        guard let renderer else { return }
        let species = renderer.species
        let aspect = species.aspectRatio
        var height = bounds.height / species.subjectHeight
        var width = height * aspect
        if width > bounds.width {
            width = bounds.width
            height = width / max(aspect, 0.01)
        }
        let rect = CGRect(x: (bounds.width - width) / 2,
                          y: -(1 - species.subjectBottom) * height,
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
        renderer.tick(dt: dt, cursor: NSEvent.mouseLocation, petRect: global)
    }
}
