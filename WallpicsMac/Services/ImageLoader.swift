import AppKit
import SwiftUI

actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage, Error>] = [:]

    enum ImageLoaderError: Error { case decodeFailed, invalidResponse }

    init() {
        let cfg = URLSessionConfiguration.default
        // Default per-host limit is 6. Wallpaper thumbnails live on one CDN (media.wallpics.app)
        // so raising the pool gives noticeable speedup when a fresh grid pops in.
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                diskCapacity: 256 * 1024 * 1024,
                                diskPath: "wallpics-thumbs")
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: Int = 720) async throws -> NSImage {
        let key = "\(url.absoluteString)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let task = inflight[key as String] { return try await task.value }

        let task = Task<NSImage, Error> { [session] in
            // Local imports use file:// URLs, which URLSession won't load — read from disk.
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                data = try await ResilientFetch.data(from: url, using: session)
            }
            // Pre-decode + downsample off the main thread. NSImage(data:) defers decoding to
            // first draw — which lands on the main thread mid-scroll and janks the grid;
            // a right-sized, immediately-cached bitmap renders instantly instead. Grid cells
            // request 720px; the featured hero requests the display's pixel size for a crisp,
            // genuinely full-resolution preview.
            let image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            guard let image else { throw ImageLoaderError.decodeFailed }
            return image
        }
        inflight[key as String] = task
        defer { inflight[key as String] = nil }

        do {
            let image = try await task.value
            cache.setObject(image, forKey: key, cost: data(for: image))
            return image
        } catch {
            throw error
        }
    }

    /// Warm the cache for cells about to scroll into view so the grid never flashes a spinner on a
    /// fast scroll. Fire-and-forget and deduped against cache/in-flight, so calling it liberally is
    /// cheap — thumbnails are ~25KB each, and it reuses the same in-flight task as the real load.
    func prefetch(_ urls: [URL], maxPixelSize: Int = 720) {
        for url in urls {
            let key = "\(url.absoluteString)|\(maxPixelSize)" as NSString
            if cache.object(forKey: key) != nil || inflight[key as String] != nil { continue }
            Task { [weak self] in _ = try? await self?.image(for: url, maxPixelSize: maxPixelSize) }
        }
    }

    private func data(for image: NSImage) -> Int {
        // Our images are CGImage-backed (NSImage(cgImage:)), whose first representation is NOT an
        // NSBitmapImageRep — the old cast always failed and returned 0, so the cache's byte-cost
        // limit never evicted and bitmaps piled up (250MB+ on a long scroll). Cost the CGImage.
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        if let rep = image.representations.first {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return 0
    }
}

/// GET with retry + short exponential backoff on transient failures — a brief connectivity blip,
/// dropped connection, 5xx, or zero-byte body (which decodes to nothing and left cards blank/black).
/// A timeout or 4xx fails fast (retrying just repeats a long wait / won't help), and cancellation is
/// honoured so a scrolled-away cell stops immediately.
enum ResilientFetch {
    static func data(from url: URL, using session: URLSession, attempts: Int = 3) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 {
                let backoff = 0.35 * Double(1 << (attempt - 1))   // 0.35s, 0.70s, …
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            if Task.isCancelled { throw CancellationError() }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                if Task.isCancelled { throw error }
                if !isRetryable(error) { throw error }   // e.g. timed-out — a retry just repeats the wait
                lastError = error
                continue
            }
            if let http = response as? HTTPURLResponse {
                if (400..<500).contains(http.statusCode) {
                    throw URLError(.badServerResponse)   // client error — fail fast
                }
                if !(200..<300).contains(http.statusCode) {
                    lastError = URLError(.badServerResponse); continue   // 5xx / other — retry
                }
            }
            if data.isEmpty { lastError = URLError(.zeroByteResource); continue }
            return data
        }
        throw lastError
    }

    /// Retry genuinely-transient failures, but NOT ones where a retry is pointless or just repeats a
    /// long wait: a timeout (the resource was already slow the whole timeout) or a cancellation.
    /// `.notConnectedToInternet` fails instantly, so retrying it briefly rides out a flaky-Wi-Fi blip.
    static func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return true }
        switch urlError.code {
        case .timedOut, .cancelled, .userCancelledAuthentication,
             .cannotParseResponse, .cannotDecodeContentData:
            return false
        default:
            return true
        }
    }
}

struct ThumbnailView: View {
    let url: URL?
    let placeholderTint: Color
    let cornerRadius: CGFloat

    @State private var image: NSImage?
    @State private var didFail = false

    init(url: URL?, placeholderTint: Color = .gray.opacity(0.2), cornerRadius: CGFloat = 0) {
        self.url = url
        self.placeholderTint = placeholderTint
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                placeholderTint
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if didFail {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: url) {
            guard let url else { return }
            image = nil
            didFail = false
            do {
                let loaded = try await ImageLoader.shared.image(for: url)
                if !Task.isCancelled {
                    withAnimation(.easeIn(duration: 0.2)) {
                        image = loaded
                    }
                }
            } catch {
                if !Task.isCancelled { didFail = true }
            }
        }
    }
}
