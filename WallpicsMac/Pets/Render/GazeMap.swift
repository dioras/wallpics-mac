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
}

struct PetPlayhead {
    var value: Double
    var responsePerSecond: Double = 11
    var maxPosesPerSecond: Double = 260

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

    mutating func step(dt: Double, target: Int, upperBound: Int, wraps: Bool = false,
                       chord: ClosedRange<Int>? = nil) {
        let count = Double(upperBound + 1)
        let wrapping = wraps && upperBound > 0
        let route = plan(to: Double(target), count: count, wrapping: wrapping, chord: chord)
        let goal = route.teleportTo == nil ? value + route.first : Double(target)
        if route.total < 0.01 {
            value = normalized(goal, count: count, upperBound: upperBound, wraps: wraps)
            return
        }
        var advance = route.total * min(1, dt * responsePerSecond)
        let limit = maxPosesPerSecond * dt
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
        guard wrapping, let chord, chord.lowerBound < chord.upperBound else { return best }
        let lo = Double(chord.lowerBound)
        let hi = Double(chord.upperBound)
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

    private func normalized(_ raw: Double, count: Double, upperBound: Int, wraps: Bool) -> Double {
        guard wraps, count > 0 else {
            return min(max(raw, 0), Double(max(upperBound, 0)))
        }
        return raw - floor(raw / count) * count
    }
}
