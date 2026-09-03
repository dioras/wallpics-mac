import Foundation

enum GazeTableRepair {
    struct CircularResult: Equatable {
        var table: [Int]
        var loop: ClosedRange<Int>
        var replacedBuckets: Int
    }

    private static let minimumBuckets = 8
    private static let minimumChainLength = 5
    private static let outlierStepFloor = 8.0
    private static let outlierStepFactor = 4.0
    private static let slopeWindow = 4

    static func pivots(for table: [Int], fallback: Int) -> (up: Int, down: Int) {
        guard let hi = table.max(), let lo = table.min() else { return (fallback, fallback) }
        return (hi, lo)
    }

    static func circular(_ table: [Int], poseCount: Int) -> CircularResult {
        let n = table.count
        let lastPose = max(poseCount - 1, 0)
        guard n >= minimumBuckets, poseCount > 1 else {
            let lo = table.min() ?? 0
            let hi = table.max() ?? lastPose
            return CircularResult(table: table, loop: lo...hi, replacedBuckets: 0)
        }

        let decreasing = dominantDirectionIsDecreasing(table)
        let (seam, rotated, kept) = bestSeam(table, decreasing: decreasing)
        let trimmed = trimSeamOutliers(rotated, kept: kept)
        let filled = fill(rotated, kept: trimmed)

        var repaired = Array(repeating: 0, count: n)
        for i in 0..<n {
            let clamped = min(max(filled[i], 0), Double(lastPose))
            repaired[(seam + 1 + i) % n] = Int(clamped.rounded())
        }
        let replaced = zip(repaired, table).filter { $0 != $1 }.count
        let first = repaired[(seam + 1) % n]
        let last = repaired[seam]
        return CircularResult(table: repaired, loop: min(first, last)...max(first, last), replacedBuckets: replaced)
    }

    private static func dominantDirectionIsDecreasing(_ table: [Int]) -> Bool {
        let n = table.count
        var negative = 0
        var positive = 0
        for i in 0..<n {
            let step = table[(i + 1) % n] - table[i]
            if step < 0 { negative += 1 } else if step > 0 { positive += 1 }
        }
        return negative >= positive
    }

    private static func bestSeam(_ table: [Int], decreasing: Bool) -> (seam: Int, rotated: [Int], kept: [Int]) {
        let n = table.count
        var best = (seam: 0, rotated: table, kept: [Int]())
        for seam in 0..<n {
            let rotated = (0..<n).map { table[(seam + 1 + $0) % n] }
            let kept = longestMonotoneChain(rotated, decreasing: decreasing)
            if kept.count > best.kept.count {
                best = (seam, rotated, kept)
            }
        }
        return best
    }

    private static func longestMonotoneChain(_ values: [Int], decreasing: Bool) -> [Int] {
        let n = values.count
        var length = Array(repeating: 1, count: n)
        var previous = Array(repeating: -1, count: n)
        for i in 0..<n {
            for j in 0..<i {
                let ordered = decreasing ? values[j] >= values[i] : values[j] <= values[i]
                if ordered && length[j] + 1 > length[i] {
                    length[i] = length[j] + 1
                    previous[i] = j
                }
            }
        }
        var end = 0
        for i in 0..<n where length[i] > length[end] { end = i }
        var chain: [Int] = []
        var cursor = end
        while cursor != -1 {
            chain.append(cursor)
            cursor = previous[cursor]
        }
        return chain.reversed()
    }

    private static func perBucketStep(_ values: [Int], from a: Int, to b: Int) -> Double {
        Double(abs(values[b] - values[a])) / Double(max(b - a, 1))
    }

    private static func trimSeamOutliers(_ values: [Int], kept: [Int]) -> [Int] {
        guard kept.count > minimumChainLength else { return kept }
        var steps: [Double] = []
        for (a, b) in zip(kept, kept.dropFirst()) {
            steps.append(perBucketStep(values, from: a, to: b))
        }
        let sorted = steps.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(outlierStepFloor, outlierStepFactor * median)

        var head = 0
        var tail = kept.count - 1
        while tail - head > minimumChainLength - 1,
              perBucketStep(values, from: kept[head], to: kept[head + 1]) > threshold {
            head += 1
        }
        while tail - head > minimumChainLength - 1,
              perBucketStep(values, from: kept[tail - 1], to: kept[tail]) > threshold {
            tail -= 1
        }
        return Array(kept[head...tail])
    }

    private static func slope(_ values: [Int], over indices: ArraySlice<Int>) -> Double {
        guard let first = indices.first, let last = indices.last, last > first else { return 0 }
        return Double(values[last] - values[first]) / Double(last - first)
    }

    private static func fill(_ values: [Int], kept: [Int]) -> [Double] {
        let n = values.count
        guard let firstKept = kept.first, let lastKept = kept.last else {
            return values.map(Double.init)
        }
        let headSlope = slope(values, over: kept.prefix(slopeWindow))
        let tailSlope = slope(values, over: kept.suffix(slopeWindow))
        var out = Array(repeating: 0.0, count: n)
        var keptIndex = 0
        for i in 0..<n {
            if i < firstKept {
                out[i] = Double(values[firstKept]) + headSlope * Double(i - firstKept)
            } else if i > lastKept {
                out[i] = Double(values[lastKept]) + tailSlope * Double(i - lastKept)
            } else {
                while keptIndex + 1 < kept.count && kept[keptIndex + 1] <= i { keptIndex += 1 }
                let lo = kept[keptIndex]
                if lo == i || keptIndex + 1 >= kept.count {
                    out[i] = Double(values[lo])
                } else {
                    let hi = kept[keptIndex + 1]
                    let t = Double(i - lo) / Double(hi - lo)
                    out[i] = Double(values[lo]) + (Double(values[hi]) - Double(values[lo])) * t
                }
            }
        }
        return out
    }
}
