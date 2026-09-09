import AVFoundation
import AppKit
import CoreMedia

final class PetStackLayer: CALayer {
    override func layoutSublayers() {
        super.layoutSublayers()
        sublayers?.forEach { $0.frame = bounds }
    }

    override var contentsScale: CGFloat {
        didSet { sublayers?.forEach { $0.contentsScale = contentsScale } }
    }
}

@MainActor
final class PetRenderer {
    let species: PetSpecies
    let layer = PetStackLayer()

    private let displayLayers = [AVSampleBufferDisplayLayer(), AVSampleBufferDisplayLayer()]
    private var activeIndex = 0
    private static let dissolveDuration: CFTimeInterval = 0.16

    private let map: GazeMap
    private var playhead: PetPlayhead
    private var sequence: PoseSequence?
    private var lastEnqueuedPose = -1
    private var clock = CMTime.zero
    private var loadTask: Task<Void, Never>?

    private(set) var isLoaded = false
    private(set) var decodeCount = 0
    private(set) var isMirrored = false
    private static let mirrorDeadBand: Double = 0.22
    private(set) var loadFailure: String?
    var onLoadFailure: ((String?) -> Void)?

    init(species: PetSpecies) {
        self.species = species
        map = GazeMap(species: species)
        playhead = PetPlayhead(pose: species.neutralPose)
        if species.wrapsAround {
            playhead.poseAngles = GazeMap.poseAngles(table: species.angleTable, poseCount: species.poseCount,
                                                     loop: species.gazeLoop, neutral: species.neutralPose)
        }
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        layer.needsDisplayOnBoundsChange = false
        for (index, display) in displayLayers.enumerated() {
            display.videoGravity = .resizeAspect
            display.isOpaque = false
            display.backgroundColor = NSColor.clear.cgColor
            display.opacity = index == activeIndex ? 1 : 0
            display.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.addSublayer(display)
        }
    }

    private var activeLayer: AVSampleBufferDisplayLayer { displayLayers[activeIndex] }
    private var standbyLayer: AVSampleBufferDisplayLayer { displayLayers[1 - activeIndex] }

    deinit {
        loadTask?.cancel()
    }

    func load() {
        guard loadTask == nil else { return }
        let url = species.mediaURL
        loadTask = Task { [weak self] in
            do {
                let loaded = try await PoseSequence.load(url: url)
                guard let self, !Task.isCancelled else { return }
                guard loaded.count > 0 else { throw PetError.emptySequence(url) }
                if loaded.count < self.species.poseCount {
                    Log.app.error("PetRenderer: \(self.species.slug, privacy: .public) declares \(self.species.poseCount) poses but the clip has \(loaded.count); clamping")
                }
                self.sequence = loaded
                self.isLoaded = true
                self.loadFailure = nil
                self.onLoadFailure?(nil)
                self.enqueue(pose: min(self.species.neutralPose, loaded.count - 1))
            } catch {
                Log.app.error("PetRenderer: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                self.loadFailure = error.localizedDescription
                self.loadTask = nil
                self.onLoadFailure?(error.localizedDescription)
            }
        }
    }

    func snapToNeutral() {
        playhead = PetPlayhead(pose: species.neutralPose)
        enqueue(pose: species.neutralPose)
    }

    @discardableResult
    func tick(dt: Double, cursor: CGPoint?, petRect: CGRect,
              sensitivity: PetSensitivity = .normal) -> Bool {
        guard let sequence else { return false }
        playhead.apply(sensitivity: sensitivity, gazeSpan: species.gazeSpan)
        let target = map.target(
            cursor: cursor,
            petRect: petRect,
            faceCenter: species.faceCenter,
            deadZone: petRect.height * species.subjectHeight * sensitivity.deadZoneFraction
        )

        let lastPose = sequence.count - 1
        var stepTarget = min(target.pose, lastPose)
        let wantsFlip = !target.holdsMirror && target.mirrored != isMirrored
        if wantsFlip && abs(target.horizontal) > Self.mirrorDeadBand {
            let pivot = min(map.pivot(upperHalf: target.upperHalf), lastPose)
            if abs(playhead.value - Double(pivot)) < 1.5 {
                setMirrored(target.mirrored)
            } else {
                stepTarget = pivot
            }
        }

        let chord = species.gazeLoop.map { min($0.lowerBound, lastPose)...min($0.upperBound, lastPose) }
        let cut = playhead.step(dt: dt, target: stepTarget, upperBound: sequence.count - 1,
                                wraps: species.wrapsAround, chord: chord)
        let pose = species.wrapsAround
            ? playhead.poseIndex % sequence.count
            : min(playhead.poseIndex, lastPose)
        if pose != lastEnqueuedPose {
            enqueue(pose: pose, dissolve: cut)
        }
        return pose != stepTarget
    }

    private func setMirrored(_ mirrored: Bool) {
        guard mirrored != isMirrored else { return }
        isMirrored = mirrored
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func enqueue(pose: Int, dissolve: Bool = false) {
        guard let sequence else { return }
        let target = dissolve && lastEnqueuedPose >= 0 ? standbyLayer : activeLayer
        let renderer = target.sampleBufferRenderer
        if renderer.status == .failed {
            Log.app.error("PetRenderer: \(self.species.slug, privacy: .public) renderer failed — \(renderer.error?.localizedDescription ?? "unknown", privacy: .public); flushing")
            renderer.flush()
        }
        if target === standbyLayer {
            target.flushAndRemoveImage()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        clock = CMTimeAdd(clock, CMTime(value: 1, timescale: 600))
        guard let buffer = sequence.displayBuffer(at: pose, presentedAt: clock) else { return }
        renderer.enqueue(buffer)
        lastEnqueuedPose = pose
        decodeCount += 1
        if target === standbyLayer {
            crossDissolve()
        }
    }

    private func crossDissolve() {
        let outgoing = activeLayer
        let incoming = standbyLayer
        activeIndex = 1 - activeIndex
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.dissolveDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        incoming.opacity = 1
        outgoing.opacity = 0
        CATransaction.commit()
    }
}

final class PetLayerView: NSView {
    private(set) var renderer: PetRenderer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(_ renderer: PetRenderer) {
        self.renderer?.layer.removeFromSuperlayer()
        self.renderer = renderer
        layer?.addSublayer(renderer.layer)
        renderer.load()
    }

    func detach() {
        renderer?.layer.removeFromSuperlayer()
        renderer = nil
    }

    func place(_ rect: CGRect, scale: CGFloat) {
        guard let renderer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = rect
        renderer.layer.contentsScale = scale
        CATransaction.commit()
    }
}
