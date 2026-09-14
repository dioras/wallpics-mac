import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LockScreenService {
    static let shared = LockScreenService()

    enum Status: Equatable {
        case idle
        case preparing(Double?)
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var pendingOperations = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var current: (kind: WallpaperRenderer.Kind, assetURL: URL)?

    var isSupported: Bool { LockScreenAerial.isSupported }

    var statusText: String? {
        switch status {
        case .idle:
            return nil
        case .preparing(let fraction):
            let base = String(localized: "Preparing lock screen…")
            guard let fraction else { return base }
            return "\(base) \(Int(fraction * 100))%"
        case .ready:
            return String(localized: "Lock screen animates too — lock your Mac to see it.")
        case .failed(let message):
            return message
        }
    }

    func isInstalled(assetURL: URL) -> Bool {
        isSupported && pendingOperations == 0 && LockScreenAerial.isInstalled(assetPath: assetURL.path)
    }

    func sync(kind: WallpaperRenderer.Kind, assetURL: URL) {
        current = (kind, assetURL)
        guard isSupported else { status = .idle; return }
        guard AppEnvironment.shared.settings.animateLockScreen, kind == .video || kind == .shader else {
            status = .idle
            enqueueRetire(reapplyDesktop: false)
            return
        }

        status = .preparing(kind == .shader ? 0 : nil)
        let target = Self.renderTarget()
        let mine = supersede()
        enqueue { [weak self] in
            guard let self, self.generation == mine else { return }
            if LockScreenAerial.isInstalled(assetPath: assetURL.path) {
                self.status = .ready
                return
            }
            do {
                let clip: URL
                switch kind {
                case .video:
                    clip = try await LockScreenAerial.transcodeToHEVC(assetURL)
                case .shader:
                    let source = try String(contentsOf: assetURL, encoding: .utf8)
                    clip = try await ShaderVideoExporter.export(shaderSource: source, pixelSize: target) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == mine, case .preparing = self.status else { return }
                            self.status = .preparing(fraction)
                        }
                    }
                default:
                    return
                }
                defer { try? FileManager.default.removeItem(at: clip) }
                try Task.checkCancellation()
                try await LockScreenAerial.install(clip: clip, assetPath: assetURL.path)
                guard self.generation == mine else { return }
                self.status = .ready
            } catch is CancellationError {
            } catch {
                guard self.generation == mine else { return }
                Log.engine.error("Lock screen clip failed: \(error.localizedDescription, privacy: .public)")
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func wallpaperDidBecomeStatic() {
        current = nil
        status = .idle
        enqueueRetire(reapplyDesktop: true)
    }

    func applyEnabledChange(_ enabled: Bool) {
        guard isSupported else { return }
        if enabled {
            if let current { sync(kind: current.kind, assetURL: current.assetURL) }
        } else {
            status = .idle
            enqueueRetire(reapplyDesktop: true)
        }
    }

    private func enqueueRetire(reapplyDesktop: Bool) {
        guard isSupported, LockScreenAerial.isActive || pendingOperations > 0 else { return }
        let mine = supersede()
        enqueue { [weak self] in
            guard let self else { return }
            guard LockScreenAerial.isActive else { return }
            do {
                try await LockScreenAerial.retire()
                if reapplyDesktop { WallpaperRenderer.shared.reapplyDesktopChoice() }
            } catch {
                guard self.generation == mine else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func supersede() -> Int {
        generation += 1
        chain?.cancel()
        return generation
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        pendingOperations += 1
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            self?.pendingOperations -= 1
        }
    }

    private static func renderTarget() -> CGSize {
        let best = NSScreen.screens.max {
            ($0.frame.width * $0.backingScaleFactor * $0.frame.height) <
            ($1.frame.width * $1.backingScaleFactor * $1.frame.height)
        }
        guard let best else { return CGSize(width: 3840, height: 2160) }
        return CGSize(width: best.frame.width * best.backingScaleFactor,
                      height: best.frame.height * best.backingScaleFactor)
    }
}
