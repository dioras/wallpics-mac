import Foundation
import MetricKit

final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private override init() {}

    func register() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Log.app.notice("MetricKit payload: \(payload.dictionaryRepresentation().count) keys")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Log.app.error("MetricKit diagnostic: \(payload.dictionaryRepresentation().count) keys")
        }
    }
}
