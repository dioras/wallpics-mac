import AVFoundation
import CoreMedia
import Foundation

final class PoseSequence: @unchecked Sendable {
    let samples: [CMSampleBuffer]
    let pixelSize: CGSize
    let frameRate: Double

    private static var cache: [String: PoseSequence] = [:]
    private static var cacheOrder: [String] = []
    private static var inflight: [String: Task<PoseSequence, Error>] = [:]
    private static let cacheLock = NSLock()
    private static let cacheLimit = 4

    private init(samples: [CMSampleBuffer], pixelSize: CGSize, frameRate: Double) {
        self.samples = samples
        self.pixelSize = pixelSize
        self.frameRate = frameRate
    }

    var count: Int { samples.count }

    static func load(url: URL) async throws -> PoseSequence {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int) ?? 0
        let key = "\(url.path)#\(stamp)#\(size)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            cacheLock.unlock()
            return hit
        }
        if let pending = inflight[key] {
            cacheLock.unlock()
            return try await pending.value
        }
        let task = Task<PoseSequence, Error> { try await read(url: url) }
        inflight[key] = task
        cacheLock.unlock()

        do {
            let sequence = try await task.value
            cacheLock.lock()
            inflight.removeValue(forKey: key)
            cache[key] = sequence
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
            cacheLock.unlock()
            return sequence
        } catch {
            cacheLock.lock()
            inflight.removeValue(forKey: key)
            cacheLock.unlock()
            throw error
        }
    }

    private static func read(url: URL) async throws -> PoseSequence {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PetError.noVideoTrack(url)
        }
        let size = try await track.load(.naturalSize)
        let rate = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw PetError.readerSetupFailed(url) }
        reader.add(output)
        guard reader.startReading() else { throw PetError.readerSetupFailed(url) }

        var samples: [CMSampleBuffer] = []
        samples.reserveCapacity(256)
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            samples.append(sample)
        }
        guard reader.status != .failed else { throw PetError.readFailed(url, reader.error) }
        guard !samples.isEmpty else { throw PetError.emptySequence(url) }
        return PoseSequence(samples: samples, pixelSize: size, frameRate: rate > 0 ? rate : 24)
    }

    func displayBuffer(at index: Int, presentedAt time: CMTime) -> CMSampleBuffer? {
        guard index >= 0, index < samples.count else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: samples[index],
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return nil }
        markDisplayImmediately(copy)
        return copy
    }

    private func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

enum PetError: LocalizedError {
    case noVideoTrack(URL)
    case readerSetupFailed(URL)
    case readFailed(URL, Error?)
    case emptySequence(URL)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let url):
            return "No video track in \(url.lastPathComponent)"
        case .readerSetupFailed(let url):
            return "Could not open \(url.lastPathComponent)"
        case .readFailed(let url, let error):
            return "Failed reading \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown")"
        case .emptySequence(let url):
            return "\(url.lastPathComponent) contains no frames"
        }
    }
}
