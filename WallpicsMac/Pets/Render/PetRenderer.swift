import AVFoundation
import AppKit
import CoreMedia

@MainActor
final class PetRenderer {
    let species: PetSpecies
    let layer = AVSampleBufferDisplayLayer()
    let allowsTransitions: Bool
    let transitionDelay: Double

    private let map: GazeMap
    private var playhead: PetPlayhead
    private let chord: ClosedRange<Int>?
    private static let apexSine = 0.85
    private static let restAfter: Double = 4
    private static let centerZoneBonus: CGFloat = 0.06
    private var heldTarget: GazeTarget?
    private var stillFor: Double = 0
    private var lastCursor: CGPoint?
    private(set) var isResting = true
    private var sequence: PoseSequence?
    private var sideSequence: PoseSequence?
    private var pettingSequence: PoseSequence?
    private var driver: PetTransitionDriver?
    private var pendingDriver: PetTransitionDriver?
    private var lastFrame: PetFrame?
    private var clock = CMTime.zero
    private var loadTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var droppedFrames = 0

    private(set) var isLoaded = false
    private(set) var decodeCount = 0
    private(set) var isMirrored = false
    private static let mirrorDeadBand: Double = 0.22
    private(set) var loadFailure: String?
    var onLoadFailure: ((String?) -> Void)?

    var canPet: Bool { driver?.canPet ?? false }
    private static let transitionRetryDelays: [Double] = [0, 20, 90, 300]

    init(species: PetSpecies, allowsTransitions: Bool = true, transitionDelay: Double = 0) {
        self.species = species
        self.allowsTransitions = allowsTransitions
        self.transitionDelay = transitionDelay
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
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
    }

    deinit {
        loadTask?.cancel()
        transitionTask?.cancel()
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
                self.loadTransitions(main: loaded)
            } catch {
                Log.app.error("PetRenderer: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                self.loadFailure = error.localizedDescription
                self.loadTask = nil
                self.onLoadFailure?(error.localizedDescription)
            }
        }
    }

    private func loadTransitions(main: PoseSequence) {
        guard allowsTransitions, transitionTask == nil, species.wrapsAround,
              let transitions = species.transitions, let loop = species.gazeLoop else { return }
        let lastPose = main.count - 1
        let clampedLoop = min(loop.lowerBound, lastPose)...min(loop.upperBound, lastPose)
        let seam = chord.map { min($0.lowerBound, lastPose)...min($0.upperBound, lastPose) }
        let angles = playhead.poseAngles
        let slug = species.slug
        let delay = transitionDelay
        transitionTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            var fetched: (side: URL, petting: URL?)?
            for delay in Self.transitionRetryDelays where fetched == nil {
                if delay > 0 {
                    Log.app.notice("PetRenderer: \(slug, privacy: .public) side clips unavailable, retrying in \(Int(delay))s")
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                fetched = await RemotePetService.shared.transitionMedia(for: transitions)
            }
            guard !Task.isCancelled else { return }
            guard let media = fetched else {
                Log.app.error("PetRenderer: \(slug, privacy: .public) side clips still unavailable, classic return until the next retry")
                self?.transitionTask = nil
                return
            }
            do {
                let side = try await PoseSequence.load(url: media.side)
                var petting: PoseSequence?
                if let url = media.petting {
                    do {
                        petting = try await PoseSequence.load(url: url)
                    } catch {
                        Log.app.error("PetRenderer: \(slug, privacy: .public) petting clip failed — \(error.localizedDescription, privacy: .public)")
                    }
                }
                guard let self, !Task.isCancelled else { return }
                guard side.pixelSize == main.pixelSize else {
                    Log.app.error("PetRenderer: \(slug, privacy: .public) side clips are \(side.pixelSize.debugDescription, privacy: .public), main is \(main.pixelSize.debugDescription, privacy: .public); keeping the classic return")
                    return
                }
                if let clip = petting, clip.pixelSize != main.pixelSize {
                    Log.app.error("PetRenderer: \(slug, privacy: .public) petting clip size differs from the main clip, petting off")
                    petting = nil
                }
                let clips = transitions.clips.filter { $0.frames.upperBound < side.count }
                guard let next = PetTransitionDriver(clips: clips, poseAngles: angles, loop: clampedLoop, seam: seam,
                                                     upperBound: lastPose,
                                                     pettingFrameCount: petting?.count ?? 0,
                                                     pettingFrameRate: petting?.frameRate ?? 24) else {
                    Log.app.error("PetRenderer: \(slug, privacy: .public) side clip data unusable (\(transitions.clips.count) clips, \(side.count) frames)")
                    return
                }
                self.sideSequence = side
                self.pettingSequence = petting
                self.pendingDriver = next
                Log.app.info("PetRenderer: \(slug, privacy: .public) returns via \(clips.count) side clips, petting \(petting == nil ? "off" : "on", privacy: .public)")
            } catch {
                Log.app.error("PetRenderer: \(slug, privacy: .public) side clips failed — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func retryTransitionsIfNeeded() {
        guard driver == nil, pendingDriver == nil, transitionTask == nil, let sequence else { return }
        loadTransitions(main: sequence)
    }

    func snapToNeutral() {
        let angles = playhead.poseAngles
        playhead = PetPlayhead(pose: species.neutralPose)
        playhead.poseAngles = angles
        heldTarget = nil
        isResting = true
        stillFor = Self.restAfter
        if var driver {
            driver.center()
            self.driver = driver
            enqueue(driver.frame)
        } else {
            enqueue(pose: species.neutralPose)
        }
    }

    @discardableResult
    func pet() -> Bool {
        guard var driver, driver.requestPetting() else { return false }
        self.driver = driver
        return true
    }

    @discardableResult
    func tick(dt: Double, cursor: CGPoint?, petRect: CGRect,
              sensitivity: PetSensitivity = .normal) -> Bool {
        guard let sequence else { return false }
        adoptPendingDriver()
        let zone = sensitivity.deadZoneFraction + (driver == nil ? 0 : Self.centerZoneBonus)
        let raw = map.target(
            cursor: cursor,
            petRect: petRect,
            faceCenter: species.faceCenter,
            deadZone: petRect.height * species.subjectHeight * zone
        )
        let target = resolveTarget(raw: raw, cursor: cursor, dt: dt)

        if var driver {
            let moving = driver.step(dt: dt, target: target, sensitivity: isResting ? .calm : sensitivity,
                                     gazeSpan: species.gazeSpan)
            self.driver = driver
            let frame = driver.frame
            if frame != lastFrame {
                enqueue(frame)
            }
            return moving
        }

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
        if PetFrame(source: .main, index: pose) != lastFrame {
            enqueue(pose: pose)
        }
        return pose != stepTarget && !playhead.isHolding
    }

    private func adoptPendingDriver() {
        guard var next = pendingDriver else { return }
        let pose = playhead.poseIndex
        let inLoop = species.gazeLoop?.contains(pose) ?? false
        guard inLoop || pose == species.neutralPose else { return }
        if inLoop { next.adopt(playhead) }
        pendingDriver = nil
        driver = next
        heldTarget = nil
        setMirrored(false)
    }

    private func resolveTarget(raw: GazeTarget, cursor: CGPoint?, dt: Double) -> GazeTarget {
        let moved = cursor.map { c in lastCursor.map { hypot(c.x - $0.x, c.y - $0.y) > 1 } ?? true } ?? false
        if moved {
            stillFor = 0
            isResting = false
        } else {
            stillFor += dt
        }
        lastCursor = cursor
        if stillFor >= Self.restAfter { isResting = true }
        if isResting {
            return GazeTarget(pose: species.neutralPose, mirrored: false, upperHalf: true,
                              holdsMirror: true, wantsCenter: true)
        }
        if raw.holdsMirror {
            if driver != nil, raw.wantsCenter { return raw }
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

    private func frames(for source: PetFrame.Source) -> PoseSequence? {
        switch source {
        case .main: return sequence
        case .side: return sideSequence
        case .petting: return pettingSequence
        }
    }

    private func enqueue(pose: Int) {
        enqueue(PetFrame(source: .main, index: pose))
    }

    private func enqueue(_ frame: PetFrame) {
        guard let source = frames(for: frame.source) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            Log.app.error("PetRenderer: \(self.species.slug, privacy: .public) renderer failed — \(renderer.error?.localizedDescription ?? "unknown", privacy: .public); flushing")
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else {
            droppedFrames += 1
            if droppedFrames % 120 == 1 {
                Log.app.notice("PetRenderer: \(self.species.slug, privacy: .public) display layer not ready, \(self.droppedFrames) frames dropped so far")
            }
            return
        }
        clock = CMTimeAdd(clock, CMTime(value: 1, timescale: 600))
        guard let buffer = source.displayBuffer(at: frame.index, presentedAt: clock) else {
            Log.app.error("PetRenderer: \(self.species.slug, privacy: .public) could not build a display buffer for \(String(describing: frame.source), privacy: .public) frame \(frame.index)")
            return
        }
        renderer.enqueue(buffer)
        lastFrame = frame
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
