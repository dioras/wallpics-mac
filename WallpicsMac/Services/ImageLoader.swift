import AppKit
import SwiftUI

actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage, Error>] = [:]

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

    func image(for url: URL) async throws -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inflight[url] { return try await task.value }

        let task = Task<NSImage, Error> { [session] in
            // Local imports use file:// URLs, which URLSession won't load — read from disk.
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (remote, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ImageLoaderError.invalidResponse
                }
                data = remote
            }
            // Pre-decode + downsample off the main thread. NSImage(data:) defers decoding to
            // first draw — which lands on the main thread mid-scroll and janks the grid;
            // a thumbnail-sized, immediately-cached bitmap renders instantly instead.
            let image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            guard let image else { throw ImageLoaderError.decodeFailed }
            return image
        }
        inflight[url] = task
        defer { inflight[url] = nil }

        do {
            let image = try await task.value
            cache.setObject(image, forKey: url as NSURL, cost: data(for: image))
            return image
        } catch {
            throw error
        }
    }

    private func data(for image: NSImage) -> Int {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return 0 }
        return rep.bytesPerRow * rep.pixelsHigh
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
