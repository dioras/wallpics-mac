import Foundation
import IOKit.ps

final class PowerMonitor: NSObject {
    enum Source { case ac, battery, unknown }

    private var runLoopSource: CFRunLoopSource?
    private(set) var currentSource: Source = .unknown
    private(set) var isLowPowerMode: Bool = false

    var onChange: ((Source, Bool) -> Void)?

    override init() {
        super.init()
        currentSource = readSource()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.refresh()
        }, context)?.takeRetainedValue()

        runLoopSource = source
        if let source = source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func lowPowerModeChanged() {
        let newValue = ProcessInfo.processInfo.isLowPowerModeEnabled
        if newValue != isLowPowerMode {
            isLowPowerMode = newValue
            onChange?(currentSource, isLowPowerMode)
        }
    }

    fileprivate func refresh() {
        let newSource = readSource()
        if newSource != currentSource {
            currentSource = newSource
            onChange?(currentSource, isLowPowerMode)
        }
    }

    private func readSource() -> Source {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unknown }

        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: AnyObject],
                  let state = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSACPowerValue { return .ac }
            if state == kIOPSBatteryPowerValue { return .battery }
        }
        return .unknown
    }
}
