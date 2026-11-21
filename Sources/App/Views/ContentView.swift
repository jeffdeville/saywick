import SwiftUI
import VoiceKeyboardCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var historyPath: [UUID] = []
    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack {
                DictateView(model: model) {
                    let id = model.recorder.restoredEntryID ?? model.recorder.sessionID
                    historyPath = model.history.entries.contains { $0.id == id } ? [id] : []
                    model.selectedTab = 1
                }
                .navigationTitle("Dictate")
                .toolbar {
                    NavigationLink { SaywickSettings(model: model) } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .id(model.recorderNavigation)
            .tabItem { Label("Dictate", systemImage: "mic") }.tag(0)
            HistoryView(model: model, path: $historyPath)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(1)
        }
        .sheet(item: $model.correctionContext) { context in
            CorrectionSheet(model: model, context: context)
        }
        .alert("Could not open correction", isPresented: Binding(get: { model.correctionError != nil }, set: { if !$0 { model.correctionError = nil } })) {
            Button("OK") { model.correctionError = nil }
        } message: { Text(model.correctionError ?? "") }
    }

}

private struct CorrectionSheet: View {
    let model: AppModel
    let context: VocabularyCorrectionContext
    @Environment(\.dismiss) private var dismiss
    @State private var heard = ""
    @State private var preferred = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Latest inserted transcript") {
                    Text(context.transcript).textSelection(.enabled)
                }
                Section("Spelling correction") {
                    TextField("Incorrect word or phrase", text: $heard)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("correctionHeard")
                    TextField("Desired spelling", text: $preferred)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("correctionPreferred")
                    Text("Enter the incorrect word or phrase exactly as it appears above. Saving enables custom words for future dictations. The text already inserted stays as it is.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("Save correction") {
                        do {
                            try model.addCorrection(heard: heard, preferred: preferred, transcript: context.transcript)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveCorrection")
                }
            }
            .navigationTitle("Fix a word")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
