import CoreGraphics
import Foundation

struct GazeTarget: Equatable {
    var pose: Int
    var mirrored: Bool
    var upperHalf: Bool
    var horizontal: Double = 0
    var holdsMirror: Bool = false
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
        let buckets = Double(angleTable.count)
        let normalized = (radians + .pi) / (2 * .pi)
        let wrapped = normalized - floor(normalized)
        return min(angleTable.count - 1, max(0, Int(wrapped * buckets)))
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
            horizontal: cos(radians)
        )
    }

    func target(cursor: CGPoint?, petRect: CGRect, faceCenter: CGPoint, deadZone: CGFloat) -> GazeTarget {
        let neutral = GazeTarget(pose: neutralPose, mirrored: false, upperHalf: true, holdsMirror: true)
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
    var responsePerSecond: Double = 11
    var maxPosesPerSecond: Double = 260
    var poseAngles: [Double?] = []

    private static let wrongSidePenalty: Double = 3
    private static let sideThreshold: Double = 0.2
    private static let detourBoost: Double = 2
    private static let seamHoldFraction: Double = 0.12
    private static let seamHoldMax: Double = 14

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
                       chord: ClosedRange<Int>? = nil) -> Bool {
        let count = Double(upperBound + 1)
        let wrapping = wraps && upperBound > 0
        if wrapping, let chord, chord.lowerBound < chord.upperBound {
            if crossesLoopEdge(target: target, chord: chord) {
                let moved = Int(value.rounded()) != target
                value = Double(target)
                return moved
            }
            if restsAcrossSeam(target: target, chord: chord) { return false }
        }
        let route = plan(to: Double(target), count: count, wrapping: wrapping, chord: chord)
        let goal = route.teleportTo == nil ? value + route.first : Double(target)
        if route.total < 0.01 {
            value = normalized(goal, count: count, upperBound: upperBound, wraps: wraps)
            return false
        }
        let hurry = boost(toward: target)
        var advance = route.total * min(1, dt * responsePerSecond * hurry)
        let limit = maxPosesPerSecond * dt * hurry
        if advance > limit { advance = limit }
        if route.total <= limit && route.total < 1 {
            value = goal
        } else if let landing = route.teleportTo, advance >= abs(route.first) {
            let remaining = advance - abs(route.first)
            value = landing + (route.second >= 0 ? remaining : -remaining)
        } else {
            value += route.first >= 0 ? advance : -advance
        }
        value = normalized(value, count: count, upperBound: upperBound, wraps: wraps)
        return false
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

    private func plan(to target: Double, count: Double, wrapping: Bool, chord: ClosedRange<Int>?) -> Route {
        let direct = delta(from: value, to: target, count: count, wrapping: wrapping)
        var best = Route(first: direct, teleportTo: nil, second: 0, total: abs(direct))
        guard wrapping, count > 1 else { return best }
        let chordAllowed: (Double, Double)? = {
            guard let chord, chord.lowerBound < chord.upperBound else { return nil }
            let lo = Double(chord.lowerBound)
            let hi = Double(chord.upperBound)
            guard value >= lo, value <= hi, target >= lo, target <= hi else { return nil }
            return (lo, hi)
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
            var cost = legCost(from: value, delta: route.first, count: count, side: side)
            if let landing = route.teleportTo {
                cost += legCost(from: landing, delta: route.second, count: count, side: side)
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

    private func legCost(from start: Double, delta: Double, count: Double, side: Double) -> Double {
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
                let wrong = max(0, -cos(angle) * side)
                cost += Self.wrongSidePenalty * wrong
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
