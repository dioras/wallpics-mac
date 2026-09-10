import AVFoundation
import AppKit
import CoreMedia

@MainActor
final class PetRenderer {
    let species: PetSpecies
    let layer = AVSampleBufferDisplayLayer()

    private let map: GazeMap
    private var playhead: PetPlayhead
    private let chord: ClosedRange<Int>?
    private static let apexSine = 0.85
    private static let restAfter: Double = 6
    private var heldTarget: GazeTarget?
    private var stillFor: Double = 0
    private var lastCursor: CGPoint?
    private(set) var isResting = true
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
        var angles: [Double?] = []
        if species.wrapsAround {
            angles = GazeMap.poseAngles(table: species.angleTable, poseCount: species.poseCount,
                                        loop: species.gazeLoop, neutral: species.neutralPose)
            playhead.poseAngles = angles
        }
        chord = Self.apexChord(loop: species.gazeLoop, table: species.angleTable, poseCount: species.poseCount)
        layer.videoGravity = .resizeAspect
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
    }

    deinit {
        loadTask?.cancel()
    }

    static func apexChord(loop: ClosedRange<Int>?, table: [Int], poseCount: Int) -> ClosedRange<Int>? {
        guard let loop, !table.isEmpty else { return loop }
        let buckets = Double(table.count)
        var apex: [Int] = []
        for (bucket, pose) in table.enumerated() where loop.contains(pose) && pose < poseCount {
            let angle = (Double(bucket) + 0.5) / buckets * 2 * .pi - .pi
            if sin(angle) >= apexSine { apex.append(pose) }
        }
        guard let first = apex.min(), let last = apex.max(), first < last else { return loop }
        return first...last
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
        heldTarget = nil
        isResting = true
        stillFor = Self.restAfter
        enqueue(pose: species.neutralPose)
    }

    @discardableResult
    func tick(dt: Double, cursor: CGPoint?, petRect: CGRect,
              sensitivity: PetSensitivity = .normal) -> Bool {
        guard let sequence else { return false }
        let raw = map.target(
            cursor: cursor,
            petRect: petRect,
            faceCenter: species.faceCenter,
            deadZone: petRect.height * species.subjectHeight * sensitivity.deadZoneFraction
        )
        let target = resolveTarget(raw: raw, cursor: cursor, dt: dt)
        playhead.apply(sensitivity: isResting ? .calm : sensitivity, gazeSpan: species.gazeSpan)

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

        let loop = species.gazeLoop.map { min($0.lowerBound, lastPose)...min($0.upperBound, lastPose) }
        let seam = chord.map { min($0.lowerBound, lastPose)...min($0.upperBound, lastPose) }
        playhead.step(dt: dt, target: stepTarget, upperBound: sequence.count - 1,
                      wraps: species.wrapsAround, chord: loop, seam: seam)
        let pose = species.wrapsAround
            ? playhead.poseIndex % sequence.count
            : min(playhead.poseIndex, lastPose)
        if pose != lastEnqueuedPose {
            enqueue(pose: pose)
        }
        return pose != stepTarget
    }

    private func resolveTarget(raw: GazeTarget, cursor: CGPoint?, dt: Double) -> GazeTarget {
        if let cursor, let last = lastCursor, hypot(cursor.x - last.x, cursor.y - last.y) > 1 {
            stillFor = 0
            isResting = false
        } else {
            stillFor += dt
        }
        lastCursor = cursor
        if stillFor >= Self.restAfter { isResting = true }
        if isResting { return GazeTarget(pose: species.neutralPose, mirrored: false, upperHalf: true, holdsMirror: true) }
        if raw.holdsMirror {
            return heldTarget ?? raw
        }
        heldTarget = raw
        return raw
    }

    private func setMirrored(_ mirrored: Bool) {
        guard mirrored != isMirrored else { return }
        isMirrored = mirrored
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func enqueue(pose: Int) {
        guard let sequence else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            Log.app.error("PetRenderer: \(self.species.slug, privacy: .public) renderer failed — \(renderer.error?.localizedDescription ?? "unknown", privacy: .public); flushing")
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        clock = CMTimeAdd(clock, CMTime(value: 1, timescale: 600))
        guard let buffer = sequence.displayBuffer(at: pose, presentedAt: clock) else { return }
        renderer.enqueue(buffer)
        lastEnqueuedPose = pose
        decodeCount += 1
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
