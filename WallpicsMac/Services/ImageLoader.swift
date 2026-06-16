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
                let (remote, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ImageLoaderError.invalidResponse
                }
                data = remote
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
