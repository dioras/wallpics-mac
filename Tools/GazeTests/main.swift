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

func testLinearPetsApproachWithoutOvershoot() {
    var rng = SystemRandomNumberGenerator()
    var overshoots = 0
    var stalls = 0
    for _ in 0..<500 {
        let upper = Int.random(in: 20...240, using: &rng)
        let start = Int.random(in: 0...upper, using: &rng)
        let target = Int.random(in: 0...upper, using: &rng)
        var head = PetPlayhead(pose: start)
        head.apply(sensitivity: .normal, gazeSpan: max(upper, 1))
        var previous = Double(start)
        var arrived = false
        for _ in 0..<400 {
            head.step(dt: 1.0 / 60.0, target: target, upperBound: upper)
            let before = previous, after = head.value
            if (Double(target) - before) * (Double(target) - after) < 0 { overshoots += 1 }
            previous = after
            if head.poseIndex == target { arrived = true; break }
        }
        if !arrived { stalls += 1 }
    }
    check(overshoots == 0, "linear pets never overshoot the target", "overshoots=\(overshoots)")
    check(stalls == 0, "linear pets always arrive within 400 ticks", "stalls=\(stalls)")
}

func testAccelerationRamp() {
    var head = PetPlayhead(pose: 0)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    let cap = head.maxPosesPerSecond / 60.0
    var advances: [Double] = []
    var previous = head.value
    for _ in 0..<12 {
        head.step(dt: 1.0 / 60.0, target: 140, upperBound: 180)
        advances.append(head.value - previous)
        previous = head.value
    }
    check(advances[0] < 0.4 * cap, "first tick starts gently", "first=\(advances[0]) cap=\(cap)")
    check(advances[0] < advances[1] && advances[1] < advances[2], "speed ramps up over the first ticks", "\(advances.prefix(4))")
    check(advances.max().map { $0 <= cap + 1e-9 } == true, "speed never exceeds the cap", "\(advances.max() ?? 0) > \(cap)")
    check(advances.last.map { abs($0 - cap) < 1e-6 } == true, "cruises at the cap once ramped", "\(advances.last ?? 0)")
    var reverse = head
    var moved: [Double] = []
    previous = reverse.value
    for _ in 0..<3 {
        reverse.step(dt: 1.0 / 60.0, target: 5, upperBound: 180)
        moved.append(previous - reverse.value)
        previous = reverse.value
    }
    check(moved[0] < 0.4 * cap, "reversing direction restarts the ramp", "\(moved)")
}

func testSensitivityPacing() {
    for level in PetSensitivity.allCases {
        var head = PetPlayhead(pose: 0)
        head.apply(sensitivity: level, gazeSpan: 150)
        let loopsPerSecond = head.maxPosesPerSecond / 150
        check(loopsPerSecond >= 0.8 && loopsPerSecond <= 2.4, "\(level.rawValue) sweeps between 0.8 and 2.4 loops per second", "\(loopsPerSecond)")
        check(head.responsePerSecond >= 4 && head.responsePerSecond <= 15, "\(level.rawValue) response in WallPets range", "\(head.responsePerSecond)")
    }
}

func testTeleportReportsCut() {
    var head = PetPlayhead(pose: 52)
    head.apply(sensitivity: .alert, gazeSpan: 150)
    var cuts = 0
    for _ in 0..<200 {
        if head.step(dt: 1.0 / 60.0, target: 140, upperBound: 180, wraps: true, chord: 13...170, seam: 50...146) { cuts += 1 }
        if head.poseIndex == 140 { break }
    }
    check(cuts == 1, "crossing the apex seam reports exactly one cut", "cuts=\(cuts)")
    var plain = PetPlayhead(pose: 60)
    plain.apply(sensitivity: .normal, gazeSpan: 150)
    var plainCuts = 0
    for _ in 0..<200 {
        if plain.step(dt: 1.0 / 60.0, target: 100, upperBound: 180, wraps: true, chord: 13...170, seam: 50...146) { plainCuts += 1 }
        if plain.poseIndex == 100 { break }
    }
    check(plainCuts == 0, "walking inside the loop reports no cut")
}

func testChordCrossingSkipsFrontDetour() {
    var head = PetPlayhead(pose: 53)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<400 {
        head.step(dt: 1.0 / 60.0, target: 135, upperBound: 180, wraps: true, chord: 51...148)
        visited.append(head.poseIndex)
        if head.poseIndex == 135 { break }
    }
    check(visited.last == 135, "reaches target across chord", "\(visited.last ?? -1)")
    check(!visited.contains(where: { (60..<130).contains($0) }), "never sweeps through the sides")
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
    let quick = trajectory(from: pet.neutral, to: right, chord: chord, angles: angles)
    let quickUp = quick.filter { upPoses.contains($0) }.count
    check(quick.last == right, "neutral -> right arrives with angles")
    check(quick.count <= 40, "neutral -> right wakes within 40 ticks", "\(quick.count)")
    check(quickUp <= quick.count, "wake walk is bounded", "\(quickUp)")
}

func testPetmakerV2Routing() {
    for (pet, chord) in v2Fixtures {
        let n = pet.table.count
        let angles = GazeMap.poseAngles(table: pet.table, poseCount: pet.poseCount, loop: chord)
        let inside = (chord.lowerBound...chord.upperBound).filter { angles[$0] == nil }
        check(inside.isEmpty, "\(pet.name): every loop pose gets an angle", "\(inside)")
        func poses(_ predicate: (Double) -> Bool) -> Set<Int> {
            Set(angles.enumerated().compactMap { item -> Int? in
                guard let a = item.element, predicate(cos(a)) else { return nil }
                return item.offset
            })
        }
        let rightPoses = poses { $0 > 0.3 }.subtracting([pet.neutral])
        let leftPoses = poses { $0 < -0.3 }.subtracting([pet.neutral])
        let right = pet.table[Int(Double(n) * 0.5)]
        let left = pet.table[0]
        let downRight = pet.table[Int(Double(n) * 0.38)]
        let out = trajectory(from: pet.neutral, to: right, chord: chord, angles: angles)
        check(out.last == right, "\(pet.name): neutral -> right arrives", "\(out.last ?? -1)")
        check(out.allSatisfy { !leftPoses.contains($0) }, "\(pet.name): neutral -> right never shows a left frame", "\(out.filter { leftPoses.contains($0) })")
        let back = trajectory(from: right, to: pet.neutral, chord: chord, angles: angles)
        check(back.last == pet.neutral, "\(pet.name): right -> neutral arrives")
        check(back.allSatisfy { !leftPoses.contains($0) }, "\(pet.name): right -> neutral never shows a left frame", "\(back.filter { leftPoses.contains($0) })")
        let toLeft = trajectory(from: pet.neutral, to: left, chord: chord, angles: angles)
        check(toLeft.last == left, "\(pet.name): neutral -> left arrives", "\(toLeft.last ?? -1)")
        check(toLeft.allSatisfy { !rightPoses.contains($0) }, "\(pet.name): neutral -> left never shows a right frame", "\(toLeft.filter { rightPoses.contains($0) })")
        let across = trajectory(from: right, to: left, chord: chord, angles: angles)
        check(across.count < 120, "\(pet.name): right -> left crosses in reasonable time", "\(across.count)")
        let dr = trajectory(from: pet.neutral, to: downRight, chord: chord, angles: angles)
        check(dr.last == downRight, "\(pet.name): neutral -> down-right arrives")
        check(dr.allSatisfy { !leftPoses.contains($0) }, "\(pet.name): neutral -> down-right never travels through the left side", "\(dr.filter { leftPoses.contains($0) })")
    }
}

func testWakeAndRest() {
    var head = PetPlayhead(pose: 180)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<120 {
        head.step(dt: 1.0 / 60.0, target: 60, upperBound: 180, wraps: true, chord: 13...170, seam: 50...146)
        visited.append(head.poseIndex)
        if head.poseIndex == 60 { break }
    }
    check(visited.last == 60 && visited.count <= 30, "wake walks into the loop quickly", "\(visited.count) ticks")
    check(!visited.contains(where: { (70..<170).contains($0) }), "wake walk takes the short way through the front tail", "\(visited)")
    var rest = PetPlayhead(pose: 60)
    rest.apply(sensitivity: .calm, gazeSpan: 150)
    var back: [Int] = []
    for _ in 0..<600 {
        rest.step(dt: 1.0 / 60.0, target: 180, upperBound: 180, wraps: true, chord: 13...170, seam: 50...146)
        back.append(rest.poseIndex)
        if rest.poseIndex == 180 { break }
    }
    check(back.last == 180 && back.count > 8, "rest eases back to neutral instead of cutting", "\(back.count) ticks")
    var inside = PetPlayhead(pose: 60)
    inside.apply(sensitivity: .normal, gazeSpan: 150)
    for _ in 0..<4 {
        inside.step(dt: 1.0 / 60.0, target: 100, upperBound: 180, wraps: true, chord: 13...170, seam: 50...146)
    }
    check(inside.poseIndex > 60 && inside.poseIndex < 100, "inside the loop still walks", "pose=\(inside.poseIndex)")
}

func testChordSnapsWhenClose() {
    var head = PetPlayhead(pose: 148)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    head.step(dt: 1.0 / 60.0, target: 65, upperBound: 180, wraps: true, chord: 51...148)
    check((51...64).contains(head.poseIndex), "teleport lands on the far side of the seam", "\(head.value)")
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

func testSubmissionGate() {
    #if DEBUG
    check(!PetAccess.requiresPaywall(forSubmissionCount: 5, state: .free), "debug builds never gate submissions")
    #else
    check(PetAccess.requiresPaywall(forSubmissionCount: PetAccess.freeSubmissions, state: .free), "free + limit reached -> paywall")
    check(PetAccess.requiresPaywall(forSubmissionCount: PetAccess.freeSubmissions + 3, state: .free), "free + over limit -> paywall")
    #endif
    check(PetAccess.freeSubmissions == 2, "two free submissions")
    check(!PetAccess.requiresPaywall(forSubmissionCount: PetAccess.freeSubmissions - 1, state: .free), "free + one left -> allowed")
    check(!PetAccess.requiresPaywall(forSubmissionCount: 9, state: .unknown), "unknown -> allowed until resolved")
    check(!PetAccess.requiresPaywall(forSubmissionCount: 9, state: .trial(expiresAt: .distantFuture)), "trial -> allowed")
    check(!PetAccess.requiresPaywall(forSubmissionCount: 9, state: .pro(expiresAt: nil)), "pro -> allowed")
}

func testWallpaperGate() {
    let limit = WallpaperAccess.freeSetsPerDay
    check(limit == 3, "three free sets per day")
    #if DEBUG
    check(WallpaperAccess.decision(isPremium: true, state: .free, setsToday: 99) == .allowed, "debug builds never gate wallpapers")
    #else
    check(WallpaperAccess.decision(isPremium: true, state: .free, setsToday: 0) == .paywall(.premiumContent), "free + premium -> paywall")
    check(WallpaperAccess.decision(isPremium: false, state: .free, setsToday: limit) == .paywall(.dailyLimit), "free + quota used -> paywall")
    check(WallpaperAccess.decision(isPremium: true, state: .free, setsToday: limit) == .paywall(.premiumContent), "premium wins over quota reason")
    #endif
    check(WallpaperAccess.decision(isPremium: false, state: .free, setsToday: limit - 1) == .allowed, "free + one set left -> allowed")
    check(WallpaperAccess.decision(isPremium: true, state: .unknown, setsToday: limit) == .allowed, "unknown -> allowed until resolved")
    check(WallpaperAccess.decision(isPremium: true, state: .trial(expiresAt: .distantFuture), setsToday: limit) == .allowed, "trial -> allowed")
    check(WallpaperAccess.decision(isPremium: true, state: .pro(expiresAt: nil), setsToday: limit) == .allowed, "pro -> allowed")
    check(WallpaperSetQuota.count(storedDay: "2026-09-18", storedCount: 3, today: "2026-09-19") == 0, "quota resets on a new day")
    check(WallpaperSetQuota.count(storedDay: "2026-09-19", storedCount: 2, today: "2026-09-19") == 2, "quota carries within the day")
    check(WallpaperSetQuota.count(storedDay: nil, storedCount: 7, today: "2026-09-19") == 0, "no stored day -> zero")
}

testLinearPetsApproachWithoutOvershoot()
testAccelerationRamp()
testSensitivityPacing()
testTeleportReportsCut()
testChordCrossingSkipsFrontDetour()
testChordFromNeutralStaysOnTargetSide()
testPetmakerRoutesNeverGlanceWrongWay()
testSideAwareRouting()
testPetmakerV2Routing()
func testSeamHold() {
    var head = PetPlayhead(pose: 146)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    let moved = head.step(dt: 1.0 / 60.0, target: 54, upperBound: 180, wraps: true, chord: 51...148)
    check(!moved && head.poseIndex == 148, "target just across the seam parks on the seam end frame", "pose=\(head.poseIndex)")
    var transit = PetPlayhead(pose: 144)
    transit.apply(sensitivity: .normal, gazeSpan: 150)
    transit.step(dt: 1.0 / 60.0, target: 53, upperBound: 180, wraps: true, chord: 51...148)
    check(transit.poseIndex == 148 && transit.isHolding, "hold never rests on a pose before the seam end", "pose=\(transit.poseIndex)")
    var far = PetPlayhead(pose: 146)
    far.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<200 {
        far.step(dt: 1.0 / 60.0, target: 80, upperBound: 180, wraps: true, chord: 51...148)
        visited.append(far.poseIndex)
        if far.poseIndex == 80 { break }
    }
    check(visited.last == 80, "target well past the seam still crosses", "\(visited.last ?? -1)")
}

func testSeamCutsAtApex() {
    let loop = 13...170
    let seam = 40...150
    var head = PetPlayhead(pose: 160)
    head.apply(sensitivity: .normal, gazeSpan: 150)
    var visited: [Int] = []
    for _ in 0..<200 {
        head.step(dt: 1.0 / 60.0, target: 25, upperBound: 180, wraps: true, chord: loop, seam: seam)
        visited.append(head.poseIndex)
        if head.poseIndex == 25 { break }
    }
    check(visited.last == 25, "up-left tail reaches up-right across the apex seam", "\(visited.last ?? -1)")
    check(!visited.contains(where: { (60..<130).contains($0) }), "apex seam route never walks through down", "\(visited)")
    var entry = PetPlayhead(pose: 180)
    entry.apply(sensitivity: .normal, gazeSpan: 150)
    var walk: [Int] = []
    for _ in 0..<120 {
        entry.step(dt: 1.0 / 60.0, target: 90, upperBound: 180, wraps: true, chord: loop, seam: seam)
        walk.append(entry.poseIndex)
        if entry.poseIndex == 90 { break }
    }
    check(walk.last == 90 && walk.count <= 40, "wake from neutral reaches down within 40 ticks", "\(walk.count)")
}

testChordSnapsWhenClose()
testWakeAndRest()
testSeamHold()
testSeamCutsAtApex()
testChordClampedToClipLength()
testOffScreenCursorReturnsToNeutral()
testPremiumGate()
testSubmissionGate()
testWallpaperGate()
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
