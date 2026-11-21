import Foundation
import MetricKit

/// Apple supplies crash/hang/CPU/disk diagnostics asynchronously, not at crash time.
/// No signal or exception handlers replace Apple's crash reporter. No network upload.
final class AppleDiagnostics: NSObject, MXMetricManagerSubscriber {
    @MainActor static let shared = AppleDiagnostics()
    @MainActor private var started = false
    @MainActor func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { DiagnosticLog.metricPayload(payload.jsonRepresentation()) }
    }
}
