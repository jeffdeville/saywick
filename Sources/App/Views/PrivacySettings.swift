import SwiftUI

struct PrivacySettings: View {
    @Bindable var model: AppModel
    @State private var diagnosticItems: [Any] = []
    @State private var sharingDiagnostics = false
    @State private var diagnosticError: String?
    var body: some View {
        Form {
            privacySection
            NavigationLink("Recording measurements") { Form { metricsSection }.navigationTitle("Measurements") }
            NavigationLink("History storage") { HistoryStorageSettings(model: model) }
            #if DEBUG
            NavigationLink("App opening diagnostics") { List(ActivationDiagnostics.shared.events.reversed()) { Text($0.label) }.navigationTitle("Recent activity") }
            #endif
        }.navigationTitle("Privacy & diagnostics")
    }
    private var privacySection: some View {
        Section("Privacy") {
            Button("Export diagnostics") {
                Task {
                    do { diagnosticItems = [try await DiagnosticLog.export()]; sharingDiagnostics = true; diagnosticError = nil }
                    catch { diagnosticError = "Could not prepare diagnostics. Try again after unlocking the device." }
                }
            }
            .sheet(isPresented: $sharingDiagnostics) { ActivityShareView(items: diagnosticItems) }
            Text("Includes recent error codes and Apple-provided crash/performance reports when available. No transcript or audio is added by Saywick. Apple reports may contain device and process details. Share only with someone you trust.")
                .font(.caption)
            if let diagnosticError { Text(diagnosticError).foregroundStyle(.red) }

            NavigationLink("Privacy policy") {
                ScrollView {
                    Text("Saywick transcribes recordings on this device. If you select OpenAI cleanup, transcript text and the selected cleanup instructions are sent to OpenAI. Regular Polish may also send relevant custom words using your API key. Other cleanup options run on this device. There are no advertising or analytics SDKs.\n\nThe one-time speech model download connects to Hugging Face and its delivery providers, which receive ordinary connection information such as your IP address.\n\nFull Access lets the keyboard exchange commands and transcripts with Saywick locally. Basic typing works without Full Access. Only names you select and confirm in the Contacts picker are saved as custom words.\n\nHistory stores text and optional audio locally. Retention settings are in Privacy & diagnostics and individual deletion controls are in History; pinned recordings are exempt from automatic expiry. Previously saved recordings remain until deleted or expired. Copies you export or share are controlled by their destination app.\n\niOS may collect and share system diagnostics according to your Apple privacy settings. Saywick keeps a bounded local diagnostic log and Apple-provided performance/crash reports. You can choose to export these for support. Saywick does not upload diagnostic reports itself.")
                        .padding().textSelection(.enabled)
                }.navigationTitle("Privacy policy")
            }
            Label("Audio stays on this iPhone. OpenAI cleanup sends transcript text when selected.", systemImage: "lock.shield")
            Text("The keyboard extension never opens the microphone. The containing app records and transcribes; the two processes exchange small JSON files in their App Group container.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var metricsSection: some View {
        Section("Live measurements") {
            metricRow("First partial", milliseconds: model.metrics.firstPartialMilliseconds)
            metricRow("First finalized text", milliseconds: model.metrics.firstFinalMilliseconds)
            metricRow("Latest phrase-final latency", milliseconds: model.metrics.latestEndOfUtteranceMilliseconds)
            LabeledContent("Final characters", value: "\(model.metrics.finalizedCharacterCount)")
        }
    }

    @ViewBuilder
    private func metricRow(_ title: String, milliseconds: Double?) -> some View {
        LabeledContent(title, value: milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
    }
}
