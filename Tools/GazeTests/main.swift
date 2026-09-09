import Foundation

var failures = 0
var passes = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passes += 1; print("PASS \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}

func unusedReversals(_ table: [Int], poseCount: Int) -> Int {
    let n = table.count
    var signs: [Int] = []
    for i in 0..<n {
        let d = table[(i + 1) % n] - table[i]
        if d != 0 { signs.append(d > 0 ? 1 : -1) }
    }
    guard !signs.isEmpty else { return 0 }
    var count = 0
    for i in 0..<signs.count where signs[i] != signs[(i + 1) % signs.count] { count += 1 }
    return count
}

func makeSpecies(_ base: LiveGazeFixture, premium: Bool = false) -> PetSpecies {
    PetSpecies(slug: "remote-\(base.id)", name: base.name, pixelWidth: 1, pixelHeight: 1, poseCount: base.poseCount,
               neutralPose: base.neutral, faceCenter: CGPoint(x: 0.5, y: 0.3), subjectHeight: 1, subjectBottom: 1,
               angleTable: base.table, mirrorTable: Array(repeating: false, count: base.table.count),
               pivotUp: 0, pivotDown: 0, isPremium: premium,
               mediaURL: URL(fileURLWithPath: "/tmp/x"), posterURL: URL(fileURLWithPath: "/tmp/y"))
}

struct LegacyPlayhead {
    var value: Double
    var responsePerSecond: Double = 11
    var maxPosesPerSecond: Double = 260
    mutating func step(dt: Double, target: Int, upperBound: Int, wraps: Bool = false) {
        let count = Double(upperBound + 1)
        var goal = Double(target)
        var delta = goal - value
        if wraps, upperBound > 0, abs(delta) > count / 2 {
            delta -= delta > 0 ? count : -count
            goal = value + delta
        }
        if abs(delta) < 0.01 {
            value = normalized(goal, count: count, upperBound: upperBound, wraps: wraps)
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
        value = normalized(value, count: count, upperBound: upperBound, wraps: wraps)
    }
    private func normalized(_ raw: Double, count: Double, upperBound: Int, wraps: Bool) -> Double {
        guard wraps, count > 0 else { return min(max(raw, 0), Double(max(upperBound, 0))) }
        return raw - floor(raw / count) * count
    }
}

func testNoChordMatchesLegacy() {
    var rng = SystemRandomNumberGenerator()
    var mismatches = 0
    for _ in 0..<2000 {
        let upper = Int.random(in: 1...240, using: &rng)
        let wraps = Bool.random(using: &rng)
        let start = Int.random(in: 0...upper, using: &rng)
        var legacy = LegacyPlayhead(value: Double(start))
        var modern = PetPlayhead(pose: start)
        for _ in 0..<12 {
            let target = Int.random(in: 0...upper, using: &rng)
            let dt = Double.random(in: 0.004...0.07, using: &rng)
            legacy.step(dt: dt, target: target, upperBound: upper, wraps: wraps)
            modern.step(dt: dt, target: target, upperBound: upper, wraps: wraps)
            if legacy.value != modern.value { mismatches += 1; break }
        }
    }
    check(mismatches == 0, "no-chord trajectories identical to legacy", "mismatches=\(mismatches)")
}

func testChordCrossingSkipsFrontDetour() {
    var head = PetPlayhead(pose: 53)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<400 {
        head.step(dt: 1.0 / 60.0, target: 143, upperBound: 180, wraps: true, chord: 51...148)
        visited.append(head.poseIndex)
        if head.poseIndex == 143 { break }
    }
    check(visited.last == 143, "reaches target across chord", "\(visited.last ?? -1)")
    check(!visited.contains(where: { (60..<140).contains($0) }), "never sweeps through the sides")
    check(!visited.contains(where: { $0 < 51 || $0 > 148 }), "never enters the front tail")
    check(visited.count < 60, "crossing is quick", "\(visited.count)")
}

func testChordFromNeutralStaysOnTargetSide() {
    var head = PetPlayhead(pose: 168)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<400 {
        head.step(dt: 1.0 / 60.0, target: 60, upperBound: 180, wraps: true, chord: 51...148)
        visited.append(head.poseIndex)
        if head.poseIndex == 60 { break }
    }
    check(visited.last == 60, "neutral to right-up arrives")
    check(!visited.contains(where: { (70..<140).contains($0) }), "neutral route does not sweep the sides")
    check(!visited.contains(where: { (100...148).contains($0) }), "neutral route never shows the far side of the loop")
}

func trajectory(from start: Int, to target: Int, chord: ClosedRange<Int>, upperBound: Int = 180, angles: [Double?] = []) -> [Int] {
    var head = PetPlayhead(pose: start)
    head.poseAngles = angles
    head.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<600 {
        head.step(dt: 1.0 / 60.0, target: target, upperBound: upperBound, wraps: true, chord: chord)
        visited.append(head.poseIndex)
        if head.poseIndex == target { break }
    }
    return visited
}

func testPetmakerRoutesNeverGlanceWrongWay() {
    guard let pet = liveFixtures.last(where: { $0.name.contains("petmaker") }) else { check(false, "pet 17 fixture present"); return }
    let chord = 13...170
    let n = pet.table.count
    func poses(_ predicate: (Double) -> Bool) -> Set<Int> {
        Set(pet.table.enumerated().filter { predicate(cos((Double($0.offset) + 0.5) / Double(n) * 2 * .pi - .pi)) }.map { $0.element })
    }
    let rightPoses = poses { $0 > 0.2 }
    let leftPoses = poses { $0 < -0.2 }
    let leftTail = Set(Array(chord.upperBound - 8...chord.upperBound))
    let rightBucket = pet.table[Int(Double(n) * 0.5)]
    let leftBucket = pet.table[0]
    let out = trajectory(from: pet.neutral, to: rightBucket, chord: chord)
    check(out.last == rightBucket, "neutral -> right arrives", "\(out.last ?? -1)")
    check(out.allSatisfy { !leftPoses.contains($0) && !leftTail.contains($0) }, "neutral -> right never shows a left frame", "\(out.filter { leftPoses.contains($0) || leftTail.contains($0) })")
    let back = trajectory(from: rightBucket, to: pet.neutral, chord: chord)
    check(back.last == pet.neutral, "right -> neutral arrives")
    check(back.allSatisfy { !leftPoses.contains($0) && !leftTail.contains($0) }, "right -> neutral never shows a left frame", "\(back.filter { leftPoses.contains($0) || leftTail.contains($0) })")
    let toLeft = trajectory(from: pet.neutral, to: leftBucket, chord: chord)
    check(toLeft.allSatisfy { !rightPoses.contains($0) }, "neutral -> left never shows a right frame", "\(toLeft.filter { rightPoses.contains($0) })")
    let across = trajectory(from: rightBucket, to: leftBucket, chord: chord)
    check(across.count < 120, "right -> left crosses in reasonable time", "\(across.count)")
    let topCross = trajectory(from: pet.table[Int(Double(n) * 0.7)], to: pet.table[Int(Double(n) * 0.85)], chord: chord)
    check(!topCross.contains(where: { $0 < chord.lowerBound || $0 > chord.upperBound }), "up-right -> up-left uses the chord, not the front tail", "\(topCross)")
}

func testSideAwareRouting() {
    guard let pet = liveFixtures.last(where: { $0.name.contains("petmaker") }) else { check(false, "pet 17 fixture present"); return }
    let chord = 13...170
    let n = pet.table.count
    let angles = GazeMap.poseAngles(table: pet.table, poseCount: pet.poseCount, loop: chord)
    check(angles.count == pet.poseCount, "pose angle per pose")
    check(angles[pet.neutral] == nil && angles[5] == nil, "front tail has no angle")
    check(angles[pet.table[Int(Double(n) * 0.5)]].map { abs($0) < 0.4 } == true, "right pose reads as right", "\(String(describing: angles[pet.table[32]]))")
    let inside = (chord.lowerBound...chord.upperBound).filter { angles[$0] == nil }
    check(inside.isEmpty, "every loop pose gets an interpolated angle", "\(inside)")
    func poses(_ predicate: (Double) -> Bool) -> Set<Int> {
        Set(pet.table.enumerated().filter { predicate(cos((Double($0.offset) + 0.5) / Double(n) * 2 * .pi - .pi)) }.map { $0.element })
    }
    let leftPoses = poses { $0 < -0.3 }
    let downRight = pet.table[Int(Double(n) * 0.38)]
    let out = trajectory(from: pet.neutral, to: downRight, chord: chord, angles: angles)
    check(out.last == downRight, "neutral -> down-right arrives")
    check(out.allSatisfy { !leftPoses.contains($0) }, "neutral -> down-right never travels through the left side", "\(out.filter { leftPoses.contains($0) })")
    let back = trajectory(from: downRight, to: pet.neutral, chord: chord, angles: angles)
    check(back.last == pet.neutral, "down-right -> neutral arrives")
    check(back.allSatisfy { !leftPoses.contains($0) }, "down-right -> neutral never travels through the left side", "\(back.filter { leftPoses.contains($0) })")
    let upPoses = Set((chord.lowerBound...chord.upperBound).filter { angles[$0].map { sin($0) > 0.85 } == true })
    let right = pet.table[Int(Double(n) * 0.5)]
    let slow = trajectory(from: pet.neutral, to: right, chord: chord)
    let quick = trajectory(from: pet.neutral, to: right, chord: chord, angles: angles)
    let slowUp = slow.filter { upPoses.contains($0) }.count
    let quickUp = quick.filter { upPoses.contains($0) }.count
    check(quick.last == right, "neutral -> right arrives with angles")
    check(quickUp * 2 <= slowUp, "neutral -> right spends at most half the frames in the up apex", "\(quickUp) vs \(slowUp)")
    check(quick.suffix(4).allSatisfy { abs($0 - right) <= 12 }, "arrival at the side is not rushed", "\(quick.suffix(4))")
}

func testChordSnapsWhenClose() {
    var head = PetPlayhead(pose: 148)
    head.step(dt: 1.0 / 60.0, target: 52, upperBound: 180, wraps: true, chord: 51...148)
    check((51...53).contains(head.poseIndex), "teleport lands next to target", "\(head.value)")
}

func testChordClampedToClipLength() {
    var head = PetPlayhead(pose: 60)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    let lastPose = 169
    let chord = min(51, lastPose)...min(175, lastPose)
    var visited: [Int] = []
    for _ in 0..<400 {
        head.step(dt: 1.0 / 60.0, target: 140, upperBound: lastPose, wraps: true, chord: chord)
        visited.append(head.poseIndex)
        if head.poseIndex == 140 { break }
    }
    check(visited.last == 140, "clamped chord still arrives")
    check(!visited.contains(where: { $0 < 20 }), "clamped chord never wraps through frame 0")
}

func testOffScreenCursorReturnsToNeutral() {
    let species = makeSpecies(liveFixtures[0])
    let map = GazeMap(species: species)
    let rect = CGRect(x: 0, y: 0, width: 300, height: 400)
    let away = map.target(cursor: nil, petRect: rect, faceCenter: species.faceCenter, deadZone: 20)
    check(away.pose == species.neutralPose && away.holdsMirror, "no cursor -> neutral pose")
    let tracked = map.target(cursor: CGPoint(x: 150, y: 700), petRect: rect, faceCenter: species.faceCenter, deadZone: 20)
    check(tracked.pose != species.neutralPose, "cursor above -> not neutral")
}

func testPremiumGate() {
    let premium = makeSpecies(liveFixtures[0], premium: true)
    #if DEBUG
    check(!PetAccess.requiresPaywall(pet: premium, state: .free), "debug builds stay unrestricted")
    #else
    check(PetAccess.requiresPaywall(pet: premium, state: .free), "premium + free -> paywall")
    #endif
    check(!PetAccess.requiresPaywall(pet: premium, state: .unknown), "premium + unknown -> allowed until resolved")
    check(!PetAccess.requiresPaywall(pet: premium, state: .pro(expiresAt: nil)), "premium + pro -> allowed")
    check(!PetAccess.requiresPaywall(pet: makeSpecies(liveFixtures[0]), state: .free), "free pet + free -> allowed")
    check(premium.remoteID == liveFixtures[0].id, "remoteID parses slug")
}

testNoChordMatchesLegacy()
testChordCrossingSkipsFrontDetour()
testChordFromNeutralStaysOnTargetSide()
testPetmakerRoutesNeverGlanceWrongWay()
testSideAwareRouting()
testChordSnapsWhenClose()
testChordClampedToClipLength()
testOffScreenCursorReturnsToNeutral()
testPremiumGate()
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
