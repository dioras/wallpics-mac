import CoreGraphics
import Foundation

struct GazeTarget: Equatable {
    var pose: Int
    var mirrored: Bool
    var upperHalf: Bool
    var horizontal: Double = 0
    var holdsMirror: Bool = false
    var wantsCenter: Bool = false
    var angle: Double? = nil
}

struct GazeMap {
    let angleTable: [Int]
    let mirrorTable: [Bool]
    let neutralPose: Int
    let poseCount: Int
    let pivotUp: Int
    let pivotDown: Int

    init(species: PetSpecies) {
        angleTable = species.angleTable
        mirrorTable = species.mirrorTable
        neutralPose = species.neutralPose
        poseCount = species.poseCount
        pivotUp = species.pivotUp
        pivotDown = species.pivotDown
    }

    private func bucket(forAngle radians: Double) -> Int {
        Self.bucket(forAngle: radians, count: angleTable.count)
    }

    static func bucket(forAngle radians: Double, count: Int) -> Int {
        let normalized = (radians + .pi) / (2 * .pi)
        let wrapped = normalized - floor(normalized)
        return min(count - 1, max(0, Int(wrapped * Double(count))))
    }

    func target(forAngle radians: Double) -> GazeTarget {
        guard !angleTable.isEmpty else {
            return GazeTarget(pose: neutralPose, mirrored: false, upperHalf: true)
        }
        let index = bucket(forAngle: radians)
        return GazeTarget(
            pose: min(max(angleTable[index], 0), max(poseCount - 1, 0)),
            mirrored: index < mirrorTable.count ? mirrorTable[index] : false,
            upperHalf: sin(radians) >= 0,
            horizontal: cos(radians),
            angle: radians
        )
    }

    static func pose(forAngle radians: Double, table: [Int]) -> Int? {
        guard !table.isEmpty else { return nil }
        return table[bucket(forAngle: radians, count: table.count)]
    }

    static func faceZone(petRect: CGRect, faceCenter: CGPoint, subjectHeight: CGFloat) -> (center: CGPoint, radius: CGFloat) {
        let center = CGPoint(x: petRect.minX + faceCenter.x * petRect.width,
                             y: petRect.maxY - faceCenter.y * petRect.height)
        return (center, petRect.height * subjectHeight * 0.3)
    }

    func target(cursor: CGPoint?, petRect: CGRect, faceCenter: CGPoint, deadZone: CGFloat) -> GazeTarget {
        let neutral = GazeTarget(pose: neutralPose, mirrored: false, upperHalf: true, holdsMirror: true, wantsCenter: true)
        guard let cursor, petRect.width > 0, petRect.height > 0 else { return neutral }
        let face = CGPoint(
            x: petRect.minX + faceCenter.x * petRect.width,
            y: petRect.maxY - faceCenter.y * petRect.height
        )
        let dx = cursor.x - face.x
        let dy = cursor.y - face.y
        if dx * dx + dy * dy < deadZone * deadZone { return neutral }
        return target(forAngle: atan2(Double(dy), Double(dx)))
    }

    func pivot(upperHalf: Bool) -> Int {
        min(max(upperHalf ? pivotUp : pivotDown, 0), max(poseCount - 1, 0))
    }

    static func poseAngles(table: [Int], poseCount: Int, loop: ClosedRange<Int>?, neutral: Int = -1) -> [Double?] {
        guard poseCount > 0, !table.isEmpty else { return [] }
        var sumSin = [Double](repeating: 0, count: poseCount)
        var sumCos = [Double](repeating: 0, count: poseCount)
        var hits = [Int](repeating: 0, count: poseCount)
        let buckets = Double(table.count)
        for (bucket, pose) in table.enumerated() where pose >= 0 && pose < poseCount && pose != neutral {
            let angle = (Double(bucket) + 0.5) / buckets * 2 * .pi - .pi
            sumSin[pose] += sin(angle)
            sumCos[pose] += cos(angle)
            hits[pose] += 1
        }
        var out: [Double?] = (0..<poseCount).map { hits[$0] > 0 ? atan2(sumSin[$0], sumCos[$0]) : nil }
        let lo = max(loop?.lowerBound ?? 0, 0)
        let hi = min(loop?.upperBound ?? (poseCount - 1), poseCount - 1)
        let maxGap = loop == nil ? 10 : poseCount
        guard lo <= hi else { return out }
        var previous: Int?
        for i in lo...hi {
            guard let a1 = out[i] else { continue }
            if let p = previous, let a0 = out[p], i - p > 1, i - p <= maxGap {
                let d = atan2(sin(a1 - a0), cos(a1 - a0))
                for k in (p + 1)..<i {
                    let t = Double(k - p) / Double(i - p)
                    out[k] = atan2(sin(a0 + d * t), cos(a0 + d * t))
                }
            }
            previous = i
        }
        if loop != nil {
            if let first = (lo...hi).first(where: { out[$0] != nil }) {
                for k in lo..<first { out[k] = out[first] }
            }
            if let last = (lo...hi).last(where: { out[$0] != nil }) {
                for k in (last + 1)...max(last + 1, hi) where k <= hi { out[k] = out[last] }
            }
        }
        return out
    }
}

struct PetPlayhead {
    var value: Double
    var responsePerSecond: Double = 9
    var maxPosesPerSecond: Double = 105
    var poseAngles: [Double?] = []
    private(set) var speed: Double = 0
    private(set) var isHolding = false

    private static let wrongSidePenalty: Double = 3
    private static let sideThreshold: Double = 0.2
    private static let detourBoost: Double = 0.8
    private static let seamHoldFraction: Double = 0.05
    private static let seamHoldMax: Double = 4
    private static let wakeTicks = 30
    private static let wakeHurry: Double = 1.5
    private static let accelerationTime: Double = 0.1
    private var hurryRemaining = 0
    private var lastDirection: Double = 0

    private struct Route {
        var first: Double
        var teleportTo: Double?
        var second: Double
        var total: Double
    }

    mutating func apply(sensitivity: PetSensitivity, gazeSpan: Int) {
        responsePerSecond = sensitivity.responsePerSecond
        maxPosesPerSecond = max(60, sensitivity.turnsPerSecond * Double(gazeSpan))
    }

    init(pose: Int) {
        value = Double(pose)
    }

    var poseIndex: Int { Int(value.rounded()) }

    @discardableResult
    mutating func step(dt: Double, target: Int, upperBound: Int, wraps: Bool = false,
                       chord: ClosedRange<Int>? = nil, seam: ClosedRange<Int>? = nil) -> Bool {
        let count = Double(upperBound + 1)
        let wrapping = wraps && upperBound > 0
        let cutRange = seam ?? chord
        if wrapping, let chord, chord.lowerBound < chord.upperBound, let cutRange {
            if crossesLoopEdge(target: target, chord: chord) {
                if chord.contains(target), hurryRemaining == 0 {
                    hurryRemaining = Self.wakeTicks
                }
            } else if restsAcrossSeam(target: target, chord: cutRange) {
                let lo = Double(cutRange.lowerBound), hi = Double(cutRange.upperBound)
                value = abs(value - lo) < abs(value - hi) ? lo : hi
                speed = 0
                isHolding = true
                return false
            }
        }
        isHolding = false
        let route = plan(to: Double(target), count: count, wrapping: wrapping, chord: chord, seam: cutRange)
        let goal = route.teleportTo == nil ? value + route.first : Double(target)
        if route.total < 0.01 {
            value = normalized(goal, count: count, upperBound: upperBound, wraps: wraps)
            speed = 0
            return false
        }
        var hurry = boost(toward: target)
        if hurryRemaining > 0 {
            hurry = max(hurry, Self.wakeHurry)
            hurryRemaining -= 1
        }
        let leg = route.first != 0 ? route.first : route.second
        let direction: Double = leg >= 0 ? 1 : -1
        if direction != lastDirection {
            speed = 0
            lastDirection = direction
        }
        let ceiling = maxPosesPerSecond * hurry
        let desired = min(route.total * responsePerSecond * hurry, ceiling)
        speed = min(desired, speed + ceiling / Self.accelerationTime * dt)
        let advance = speed * dt
        var cut = false
        if route.total <= ceiling * dt && route.total < 1 {
            value = goal
            speed = 0
        } else if let landing = route.teleportTo, advance >= abs(route.first) {
            let remaining = advance - abs(route.first)
            value = landing + (route.second >= 0 ? remaining : -remaining)
            cut = true
        } else {
            value += direction * advance
        }
        value = normalized(value, count: count, upperBound: upperBound, wraps: wraps)
        return cut
    }

    private func restsAcrossSeam(target: Int, chord: ClosedRange<Int>) -> Bool {
        let lo = Double(chord.lowerBound)
        let hi = Double(chord.upperBound)
        let band = min(Self.seamHoldMax, (hi - lo) * Self.seamHoldFraction)
        guard band >= 1 else { return false }
        let t = Double(target)
        let nearLow = { (x: Double) in x >= lo && x <= lo + band }
        let nearHigh = { (x: Double) in x >= hi - band && x <= hi }
        return (nearLow(t) && nearHigh(value)) || (nearHigh(t) && nearLow(value))
    }

    private func crossesLoopEdge(target: Int, chord: ClosedRange<Int>) -> Bool {
        let insideNow = value >= Double(chord.lowerBound) && value <= Double(chord.upperBound)
        let insideTarget = chord.contains(target)
        return insideNow != insideTarget
    }

    private func delta(from a: Double, to b: Double, count: Double, wrapping: Bool) -> Double {
        var d = b - a
        if wrapping, abs(d) > count / 2 {
            d -= d > 0 ? count : -count
        }
        return d
    }

    private func plan(to target: Double, count: Double, wrapping: Bool, chord: ClosedRange<Int>?,
                      seam: ClosedRange<Int>? = nil) -> Route {
        let direct = delta(from: value, to: target, count: count, wrapping: wrapping)
        var best = Route(first: direct, teleportTo: nil, second: 0, total: abs(direct))
        guard wrapping, count > 1 else { return best }
        let chordAllowed: (Double, Double)? = {
            guard let chord, chord.lowerBound < chord.upperBound else { return nil }
            let loopLo = Double(chord.lowerBound)
            let loopHi = Double(chord.upperBound)
            guard value >= loopLo, value <= loopHi, target >= loopLo, target <= loopHi else { return nil }
            let cut = seam ?? chord
            guard cut.lowerBound < cut.upperBound else { return nil }
            return (Double(cut.lowerBound), Double(cut.upperBound))
        }()
        guard poseAngles.count == Int(count) else {
            guard let (lo, hi) = chordAllowed else { return best }
            for (entry, exit) in [(lo, hi), (hi, lo)] {
                let approach = delta(from: value, to: entry, count: count, wrapping: wrapping)
                let departure = delta(from: exit, to: target, count: count, wrapping: wrapping)
                let total = abs(approach) + abs(departure)
                if total < best.total - 0.5 {
                    best = Route(first: approach, teleportTo: exit, second: departure, total: total)
                }
            }
            return best
        }
        let side = preferredSide(target: target)
        let startSide = sideOf(pose: poseIndex)
        let forward = (target - value).truncatingRemainder(dividingBy: count) < 0
            ? (target - value).truncatingRemainder(dividingBy: count) + count
            : (target - value).truncatingRemainder(dividingBy: count)
        var candidates = [Route(first: forward, teleportTo: nil, second: 0, total: forward),
                          Route(first: forward - count, teleportTo: nil, second: 0, total: count - forward)]
        if let (lo, hi) = chordAllowed {
            for (entry, exit) in [(lo, hi), (hi, lo)] {
                let approach = delta(from: value, to: entry, count: count, wrapping: wrapping)
                let departure = delta(from: exit, to: target, count: count, wrapping: wrapping)
                candidates.append(Route(first: approach, teleportTo: exit, second: departure,
                                        total: abs(approach) + abs(departure)))
            }
        }
        var bestCost = Double.infinity
        for route in candidates {
            var cost = legCost(from: value, delta: route.first, count: count, side: side, startSide: startSide)
            if let landing = route.teleportTo {
                cost += legCost(from: landing, delta: route.second, count: count, side: side, startSide: startSide)
            }
            if cost < bestCost - 0.5 || (abs(cost - bestCost) <= 0.5 && route.total < best.total) {
                bestCost = cost
                best = route
            }
        }
        return best
    }

    private func preferredSide(target: Double) -> Double {
        for pose in [Int(target.rounded()), poseIndex] {
            guard pose >= 0, pose < poseAngles.count, let angle = poseAngles[pose] else { continue }
            let c = cos(angle)
            if abs(c) > Self.sideThreshold { return c > 0 ? 1 : -1 }
        }
        return 0
    }

    private func sideOf(pose: Int) -> Double {
        guard pose >= 0, pose < poseAngles.count, let angle = poseAngles[pose] else { return 0 }
        let c = cos(angle)
        return abs(c) > Self.sideThreshold ? (c > 0 ? 1 : -1) : 0
    }

    private func legCost(from start: Double, delta: Double, count: Double, side: Double, startSide: Double = 0) -> Double {
        let steps = Int(abs(delta).rounded())
        guard steps > 0 else { return 0 }
        let direction: Double = delta >= 0 ? 1 : -1
        var cost = 0.0
        var pose = start
        for _ in 0..<steps {
            pose += direction
            if pose >= count { pose -= count }
            if pose < 0 { pose += count }
            cost += 1
            let index = Int(pose.rounded())
            if side != 0, index >= 0, index < poseAngles.count, let angle = poseAngles[index] {
                let frameSide = cos(angle)
                let leavingOwnSide = startSide != 0 && startSide != side && frameSide * startSide > Self.sideThreshold
                if !leavingOwnSide {
                    let wrong = max(0, -frameSide * side)
                    cost += Self.wrongSidePenalty * wrong
                }
            }
        }
        return cost
    }

    private func boost(toward target: Int) -> Double {
        guard !poseAngles.isEmpty else { return 1 }
        let current = poseIndex
        guard current >= 0, current < poseAngles.count, target >= 0, target < poseAngles.count else { return 1 }
        let error: Double
        switch (poseAngles[current], poseAngles[target]) {
        case let (a?, b?):
            error = abs(atan2(sin(a - b), cos(a - b)))
        case (nil, nil):
            error = 0
        default:
            error = .pi / 2
        }
        return 1 + Self.detourBoost * min(1, error / (.pi / 2))
    }

    private func normalized(_ raw: Double, count: Double, upperBound: Int, wraps: Bool) -> Double {
        guard wraps, count > 0 else {
            return min(max(raw, 0), Double(max(upperBound, 0)))
        }
        return raw - floor(raw / count) * count
    }
}

struct PetFrame: Equatable {
    enum Source: Equatable {
        case main, side, petting
    }

    var source: Source
    var index: Int
}

struct PettingStroke {
    static let slack: CGFloat = 1.6
    let threshold: CGFloat
    private var last: CGPoint
    private(set) var travelled: CGFloat = 0

    init(at point: CGPoint, threshold: CGFloat) {
        last = point
        self.threshold = threshold
    }

    mutating func move(to point: CGPoint) -> Bool {
        travelled += hypot(point.x - last.x, point.y - last.y)
        last = point
        return travelled >= threshold
    }
}

struct PetTransitionDriver {
    enum Stage: Equatable {
        case loop
        case track(Int)
        case petting
    }

    let clips: [PetReturnClip]
    let pettingFrameCount: Int
    let pettingFrameRate: Double
    private let poseAngles: [Double?]
    private let loop: ClosedRange<Int>
    private let seam: ClosedRange<Int>?
    private let upperBound: Int
    private let home: Int
    private(set) var stage: Stage
    private(set) var playhead: PetPlayhead
    private var track: PetPlayhead
    private var lastTrack: Int
    private var pettingPosition: Double = 0
    private(set) var pettingRequested = false

    private static let maxTrackSpeedup: Double = 3

    init?(clips: [PetReturnClip], poseAngles: [Double?], loop: ClosedRange<Int>, seam: ClosedRange<Int>?,
          upperBound: Int, pettingFrameCount: Int = 0, pettingFrameRate: Double = 24) {
        let usable = clips.filter { loop.contains($0.pivot) && $0.frames.count > 1 }
        guard !usable.isEmpty, loop.lowerBound >= 0, loop.upperBound <= upperBound else { return nil }
        self.clips = usable
        self.poseAngles = poseAngles
        self.loop = loop
        self.seam = seam
        self.upperBound = upperBound
        self.pettingFrameCount = max(pettingFrameCount, 0)
        self.pettingFrameRate = pettingFrameRate > 0 ? pettingFrameRate : 24
        home = usable.firstIndex { $0.direction == .up } ?? 0
        lastTrack = home
        stage = .track(home)
        track = PetPlayhead(pose: usable[home].frames.count - 1)
        var head = PetPlayhead(pose: usable[home].pivot)
        head.poseAngles = poseAngles
        playhead = head
    }

    var canPet: Bool { pettingFrameCount > 1 }

    var isCentered: Bool {
        guard case .track(let i) = stage else { return false }
        return track.value >= centerPosition(i) - 0.5
    }

    var frame: PetFrame {
        switch stage {
        case .loop:
            return PetFrame(source: .main, index: playhead.poseIndex % (upperBound + 1))
        case .track(let i):
            let clip = clips[i]
            let offset = min(max(track.poseIndex, 0), clip.frames.count - 1)
            return PetFrame(source: .side, index: clip.frames.lowerBound + offset)
        case .petting:
            return PetFrame(source: .petting, index: min(max(Int(pettingPosition), 0), pettingFrameCount - 1))
        }
    }

    mutating func adopt(_ legacy: PetPlayhead) {
        guard loop.contains(legacy.poseIndex) else { return }
        var head = legacy
        head.poseAngles = poseAngles
        playhead = head
        stage = .loop
    }

    mutating func center() {
        pettingRequested = false
        enterTrack(home, at: centerPosition(home))
    }

    @discardableResult
    mutating func requestPetting() -> Bool {
        guard canPet, stage != .petting, !pettingRequested else { return false }
        pettingRequested = true
        return true
    }

    mutating func step(dt: Double, target: GazeTarget, sensitivity: PetSensitivity, gazeSpan: Int) -> Bool {
        playhead.apply(sensitivity: sensitivity, gazeSpan: gazeSpan)
        switch stage {
        case .petting:
            pettingPosition += dt * pettingFrameRate
            if pettingPosition >= Double(pettingFrameCount) {
                pettingRequested = false
                enterTrack(lastTrack, at: centerPosition(lastTrack))
            }
            return true
        case .loop:
            guard target.wantsCenter || pettingRequested else {
                stepLoop(dt: dt, target: target.pose)
                return playhead.poseIndex != target.pose && !playhead.isHolding
            }
            let i = nearestClip(toPose: playhead.poseIndex)
            if arrived(atPivotOf: i) {
                enterTrack(i, at: 0)
                return true
            }
            stepLoop(dt: dt, target: clips[i].pivot)
            return true
        case .track:
            return stepTrack(dt: dt, target: target, sensitivity: sensitivity, gazeSpan: gazeSpan)
        }
    }

    private mutating func stepTrack(dt: Double, target: GazeTarget, sensitivity: PetSensitivity, gazeSpan: Int) -> Bool {
        guard case .track(let i) = stage else { return false }
        let end = centerPosition(i)
        if target.wantsCenter || pettingRequested {
            if track.value >= end - 0.5 {
                track.value = end
                guard pettingRequested else { return false }
                lastTrack = i
                pettingPosition = 0
                stage = .petting
                return true
            }
            advanceTrack(i, dt: dt, goal: Int(end), sensitivity: sensitivity, gazeSpan: gazeSpan)
            return true
        }
        let best = bestClip(for: target)
        if best != i, track.value >= end - 0.5 {
            enterTrack(best, at: centerPosition(best))
            return true
        }
        let goal = best == i || track.value < end / 2 ? 0 : Int(end)
        if goal == 0, track.value <= 0.5 {
            lastTrack = i
            var head = PetPlayhead(pose: clips[i].pivot)
            head.poseAngles = poseAngles
            head.apply(sensitivity: sensitivity, gazeSpan: gazeSpan)
            playhead = head
            stage = .loop
            stepLoop(dt: dt, target: target.pose)
            return true
        }
        advanceTrack(i, dt: dt, goal: goal, sensitivity: sensitivity, gazeSpan: gazeSpan)
        return true
    }

    private mutating func advanceTrack(_ i: Int, dt: Double, goal: Int, sensitivity: PetSensitivity, gazeSpan: Int) {
        track.apply(sensitivity: sensitivity, gazeSpan: gazeSpan)
        let quarterTurn = max(Double(loop.count) / 4, 1)
        let speedup = min(max(centerPosition(i) / quarterTurn, 1), Self.maxTrackSpeedup)
        track.maxPosesPerSecond *= speedup
        track.step(dt: dt, target: goal, upperBound: clips[i].frames.count - 1)
    }

    private mutating func stepLoop(dt: Double, target: Int) {
        playhead.step(dt: dt, target: target, upperBound: upperBound, wraps: true, chord: loop, seam: seam)
    }

    private mutating func enterTrack(_ i: Int, at position: Double) {
        stage = .track(i)
        track = PetPlayhead(pose: Int(position.rounded()))
    }

    private func centerPosition(_ i: Int) -> Double {
        Double(clips[i].frames.count - 1)
    }

    private func arrived(atPivotOf i: Int) -> Bool {
        let pivot = clips[i].pivot
        if abs(playhead.value - Double(pivot)) <= 1 { return true }
        guard pivot == loop.lowerBound || pivot == loop.upperBound else { return false }
        return abs(playhead.value - Double(loop.lowerBound)) <= 1 || abs(playhead.value - Double(loop.upperBound)) <= 1
    }

    private func angle(ofPose pose: Int) -> Double? {
        guard pose >= 0, pose < poseAngles.count else { return nil }
        return poseAngles[pose]
    }

    private func clipAngle(_ i: Int) -> Double {
        angle(ofPose: clips[i].pivot) ?? clips[i].direction.angle
    }

    private func closestClip(toAngle angle: Double) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for i in clips.indices {
            let a = clipAngle(i)
            let distance = abs(atan2(sin(angle - a), cos(angle - a)))
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    private func closestClip(toFrame pose: Int) -> Int {
        clips.indices.min { abs(clips[$0].pivot - pose) < abs(clips[$1].pivot - pose) } ?? 0
    }

    private func nearestClip(toPose pose: Int) -> Int {
        if let a = angle(ofPose: pose) { return closestClip(toAngle: a) }
        return closestClip(toFrame: pose)
    }

    private func bestClip(for target: GazeTarget) -> Int {
        if let a = target.angle ?? angle(ofPose: target.pose) { return closestClip(toAngle: a) }
        return closestClip(toFrame: target.pose)
    }
}
