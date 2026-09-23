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
    @ObservationIgnored private var verification: Task<Void, Never>?
    @ObservationIgnored private var pendingOperations = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var current: (kind: WallpaperRenderer.Kind, assetURL: URL)?
    @ObservationIgnored private var desktopPictureAppliedAt: Date?

    private static let posterSettleSeconds: TimeInterval = 3
    private static let verificationDelays: [TimeInterval] = [3, 10, 20]
    private static let maxRepairs = 2

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

    func willInstallImmediately(kind: WallpaperRenderer.Kind, assetURL: URL) -> Bool {
        guard wantsAerial(kind: kind) else { return false }
        return LockScreenAerial.isInstalled(assetPath: assetURL.path)
            || LockScreenAerial.cachedClip(for: assetURL.path, variant: Self.clipVariant(kind: kind)) != nil
    }

    private static func clipVariant(kind: WallpaperRenderer.Kind) -> String {
        guard kind == .shader else { return "" }
        let target = renderTarget()
        return "\(Int(target.width))x\(Int(target.height))"
    }

    func noteDesktopPictureApplied() {
        desktopPictureAppliedAt = Date()
    }

    func sync(kind: WallpaperRenderer.Kind, assetURL: URL) {
        current = (kind, assetURL)
        guard isSupported else { status = .idle; return }
        guard wantsAerial(kind: kind) else {
            status = .idle
            enqueueRetire(reapplyDesktop: false)
            return
        }

        status = .preparing(kind == .shader ? 0 : nil)
        let target = Self.renderTarget()
        let variant = Self.clipVariant(kind: kind)
        let mine = supersede()
        enqueue { [weak self] in
            guard let self, self.generation == mine else { return }
            if LockScreenAerial.isInstalled(assetPath: assetURL.path) {
                self.status = .ready
                return
            }
            do {
                let clip = try await self.prepareClip(kind: kind, assetURL: assetURL, target: target, variant: variant, generation: mine)
                defer { if !LockScreenAerial.isCachedClip(clip) { try? FileManager.default.removeItem(at: clip) } }
                try Task.checkCancellation()
                await self.waitForDesktopPictureToSettle()
                try Task.checkCancellation()
                try await LockScreenAerial.install(clip: clip, assetPath: assetURL.path)
                guard self.generation == mine else { return }
                self.status = .ready
                self.scheduleVerification(assetURL: assetURL, variant: variant, generation: mine)
            } catch is CancellationError {
            } catch {
                guard self.generation == mine else { return }
                Log.engine.error("Lock screen clip failed: \(error.localizedDescription, privacy: .public)")
                self.fail(error)
            }
        }
    }

    func reassert() {
        guard isSupported, let current, wantsAerial(kind: current.kind), pendingOperations == 0 else { return }
        if case .failed = status { return }
        guard !LockScreenAerial.isInstalled(assetPath: current.assetURL.path) else { return }
        Log.engine.notice("Lock screen aerial is no longer the desktop choice, reinstalling")
        sync(kind: current.kind, assetURL: current.assetURL)
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

    private func wantsAerial(kind: WallpaperRenderer.Kind) -> Bool {
        isSupported && AppEnvironment.shared.settings.animateLockScreen && (kind == .video || kind == .shader)
    }

    private func prepareClip(kind: WallpaperRenderer.Kind, assetURL: URL, target: CGSize, variant: String, generation mine: Int) async throws -> URL {
        if let cached = LockScreenAerial.cachedClip(for: assetURL.path, variant: variant) {
            Log.engine.info("Lock screen clip reused from cache")
            return cached
        }
        let fresh: URL
        if kind == .shader {
            let source = try String(contentsOf: assetURL, encoding: .utf8)
            fresh = try await ShaderVideoExporter.export(shaderSource: source, pixelSize: target) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == mine, case .preparing = self.status else { return }
                    self.status = .preparing(fraction)
                }
            }
        } else {
            fresh = try await LockScreenAerial.transcodeToHEVC(assetURL)
        }
        return LockScreenAerial.storeClip(fresh, for: assetURL.path, variant: variant)
    }

    private func waitForDesktopPictureToSettle() async {
        guard let applied = desktopPictureAppliedAt else { return }
        let remaining = Self.posterSettleSeconds - Date().timeIntervalSince(applied)
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    private func scheduleVerification(assetURL: URL, variant: String, generation mine: Int) {
        verification?.cancel()
        verification = Task { @MainActor [weak self] in
            var repairs = 0
            for delay in Self.verificationDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.generation == mine, self.pendingOperations == 0 else { return }
                if LockScreenAerial.isInstalled(assetPath: assetURL.path) { continue }
                guard repairs < Self.maxRepairs, let clip = LockScreenAerial.cachedClip(for: assetURL.path, variant: variant) else {
                    Log.engine.error("Lock screen aerial lost after install (repairs: \(repairs, privacy: .public))")
                    self.fail(LockScreenAerial.Failure.lost)
                    return
                }
                repairs += 1
                Log.engine.notice("Lock screen aerial was overwritten after install, repairing (\(repairs, privacy: .public))")
                self.enqueue { [weak self] in
                    guard let self, self.generation == mine else { return }
                    do {
                        try await LockScreenAerial.install(clip: clip, assetPath: assetURL.path)
                    } catch is CancellationError {
                    } catch {
                        guard self.generation == mine else { return }
                        Log.engine.error("Lock screen repair failed: \(error.localizedDescription, privacy: .public)")
                        self.fail(error)
                    }
                }
                await self.chain?.value
                guard self.generation == mine else { return }
                if case .failed = self.status { return }
            }
            guard repairs > 0 else { return }
            try? await Task.sleep(for: .seconds(Self.verificationDelays[0]))
            guard let self, !Task.isCancelled, self.generation == mine, self.pendingOperations == 0 else { return }
            if !LockScreenAerial.isInstalled(assetPath: assetURL.path) {
                Log.engine.error("Lock screen aerial lost again after the last repair")
                self.fail(LockScreenAerial.Failure.lost)
            }
        }
    }

    private func fail(_ error: Error) {
        status = .failed(error.localizedDescription)
        WallpaperRenderer.shared.reapplyDesktopChoice()
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
        verification?.cancel()
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
