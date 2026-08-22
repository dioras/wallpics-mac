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

    func target(cursor: CGPoint, petRect: CGRect, faceCenter: CGPoint, deadZone: CGFloat) -> GazeTarget {
        let neutral = GazeTarget(pose: neutralPose, mirrored: false, upperHalf: true, holdsMirror: true)
        guard petRect.width > 0, petRect.height > 0 else { return neutral }
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

    mutating func apply(sensitivity: PetSensitivity, gazeSpan: Int) {
        responsePerSecond = sensitivity.responsePerSecond
        maxPosesPerSecond = max(60, sensitivity.turnsPerSecond * Double(gazeSpan))
    }

    init(pose: Int) {
        value = Double(pose)
    }

    var poseIndex: Int { Int(value.rounded()) }

    mutating func step(dt: Double, target: Int, upperBound: Int) {
        let goal = Double(target)
        let delta = goal - value
        if abs(delta) < 0.01 {
            value = goal
            return
        }
        var advance = delta * min(1, dt * responsePerSecond)
        let limit = maxPosesPerSecond * dt
        if abs(advance) > limit { advance = advance > 0 ? limit : -limit }
        if abs(delta) <= limit && abs(delta) < 1 {
            value = goal
        } else {
            value += advance
        }
        value = min(max(value, 0), Double(max(upperBound, 0)))
    }
}
