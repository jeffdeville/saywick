import SwiftUI
import UniformTypeIdentifiers
import VoiceKeyboardCore

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var importing = false
    @State private var deleting: TranscriptHistoryEntry?
    @State private var deletingShared: URL?
    var body: some View {
        NavigationStack {
            List {
                Text(model.history.message).font(.caption).accessibilityIdentifier("historyStatus")
                if model.history.isWorking { Button("Cancel operation", role: .destructive) { model.history.cancelWork() } }
                if !model.history.inbox.isEmpty {
                    Section("Shared audio — waiting to import") {
                        ForEach(model.history.inbox, id: \.self) { url in
                            Button("Import shared \(url.pathExtension.uppercased()) recording") { model.history.importAudio(url, fromInbox: true) }
                                .disabled(model.isBusy || model.history.isWorking)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { deletingShared = url }.disabled(model.isBusy || model.history.isWorking)
                                }
                        }
                    }
                }
                if model.history.entries.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Dictate or import audio to save and transcribe it on device."))
                }
                ForEach(model.history.entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                    || $0.runs.contains { $0.rawText.localizedCaseInsensitiveContains(search) || $0.finalText.localizedCaseInsensitiveContains(search) } }) { entry in
                    NavigationLink { HistoryDetailView(model: model, entryID: entry.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).lineLimit(2)
                            Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            Text("\(entry.runs.count) runs · \(entry.hasAudio ? "Audio retained" : "Text only")\(entry.pinned ? " · Pinned" : "")").font(.caption)
                            Text(entry.status).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = entry }.disabled(model.isBusy || model.history.isWorking)
                        Button(entry.pinned ? "Unpin" : "Pin") { model.history.pin(entry) }.tint(.orange).disabled(model.isBusy || model.history.isWorking)
                    }
                }
                Section("Retention — local, excluded from backups") {
                    Toggle("Keep audio for playback", isOn: $model.history.keepAudio)
                    Picker("Keep unpinned text", selection: $model.history.textDays) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("Forever").tag(0)
                    }
                    Picker("Keep unpinned audio", selection: $model.history.audioDays) {
                        Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("Forever").tag(0)
                    }
                    Text("Expiry is checked when History refreshes or Saywick starts. Pin entries to keep them. Turning audio off affects future dictations; imports retain audio. Clear resets active dictation, not saved history. Delete is permanent.").font(.caption)
                }.disabled(model.isBusy || model.history.isWorking)
            }
            .navigationTitle("History")
            .searchable(text: $search)
            .toolbar {
                Button("Import Audio", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.isBusy || model.history.isWorking)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): model.history.importAudio(url)
                case .failure(let error): model.history.message = error.localizedDescription
                }
            }
            .confirmationDialog("Permanently delete this recording and every comparison?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete recording and text", role: .destructive) {
                    if let deleting { model.history.delete(deleting) }; deleting = nil
                }
            }
            .onAppear { if !model.isBusy && !model.history.isWorking { model.history.reload() } }
            .confirmationDialog("Permanently delete this queued audio file?", isPresented: Binding(
                get: { deletingShared != nil }, set: { if !$0 { deletingShared = nil } })) {
                Button("Delete shared audio", role: .destructive) {
                    if let deletingShared { model.history.deleteSharedAudio(deletingShared) }; deletingShared = nil
                }
            }
        }
    }
}

private struct HistoryDetailView: View {
    @Bindable var model: AppModel
    let entryID: UUID
    @State private var deleteAudio = false
    @State private var sharedItems: [Any] = []
    @State private var sharing = false
    @State private var heard = ""
    @State private var preferred = ""
    var entry: TranscriptHistoryEntry? { model.history.entries.first { $0.id == entryID } }
    var disabled: Bool { model.isBusy || model.history.isWorking }
    var body: some View {
        Form {
            if let entry {
                Section {
                    Text(entry.title).font(.headline)
                    Text(entry.createdAt.formatted()).font(.caption)
                    Text(entry.source).font(.caption)
                    Text(model.history.message).font(.caption)
                    Button(entry.pinned ? "Unpin recording" : "Pin recording") { model.history.pin(entry) }.disabled(disabled)
                    if entry.hasAudio {
                        Button(model.history.playingID == entry.id ? "Stop playback" : "Play original audio") { model.history.play(entry) }.disabled(disabled)
                        Button("Delete audio only", role: .destructive) { deleteAudio = true }.disabled(disabled)
                    }
                }
                Section("Transcribe audio") {
                    Button("Transcribe with Parakeet") { run(entry) }
                        .accessibilityIdentifier("runComparison").disabled(disabled || !entry.hasAudio)
                    Text("Saves a new on-device transcript using current cleanup and custom words. Earlier transcripts are kept.").font(.caption)
                }.disabled(disabled)
                if model.history.isWorking { Button("Cancel operation") { model.history.cancelWork() } }
                ForEach(entry.runs) { result in
                    Section(result.model) {
                        Text(result.createdAt.formatted()).font(.caption)
                        Text("\(result.cleanup.displayName) · \(result.elapsedSeconds, specifier: "%.1f") seconds").font(.caption)
                        if let error = result.error { Text(error).foregroundStyle(.orange) }
                        DisclosureGroup("Run configuration") {
                            Text("Cleanup preference: \(result.cleanupInstructions)")
                            Text("Custom words: \(result.vocabulary.isEmpty ? "None" : result.vocabulary)")
                        }.font(.caption)
                        Text("Original").font(.headline)
                        Text(result.rawText.isEmpty ? "No recognized text" : result.rawText).textSelection(.enabled)
                        Button("Copy original") { UIPasteboard.general.string = result.rawText }
                        Button("Use original in keyboard") { model.restoreOutput(result.rawText) }.disabled(disabled || result.rawText.isEmpty)
                        Text("Final").font(.headline)
                        Text(result.finalText.isEmpty ? "No final text" : result.finalText).textSelection(.enabled)
                        Button("Copy final") { UIPasteboard.general.string = result.finalText }
                        Button("Use final in keyboard") { model.restoreOutput(result.finalText) }.disabled(disabled || result.finalText.isEmpty)
                        Button("Reprocess original with current settings") {
                            model.history.compare(entry, engine: result.engine, cleanup: model.selectedPostProcessorID,
                                instructions: model.customCleanupInstructions, vocabulary: model.customWordsEnabled ? model.customWordsText : "", reprocess: result)
                        }.disabled(disabled || result.rawText.isEmpty)
                    }
                }
                Section("Add a spelling correction") {
                    TextField("Heard spelling", text: $heard).autocorrectionDisabled()
                    TextField("Preferred spelling", text: $preferred).autocorrectionDisabled()
                    Button("Save correction") {
                        do { try model.addCorrection(heard: heard, preferred: preferred); model.history.message = "Correction saved for future runs." }
                        catch { model.history.message = error.localizedDescription }
                    }.disabled(disabled || heard.isEmpty || preferred.isEmpty)
                }
                Section("Export") {
                    Button("Share text / Save to Notes") {
                        sharedItems = [entry.runs.last(where: { $0.error == nil })?.finalText ?? ""]; sharing = true
                    }
                    Button("Export .txt") { export(entry, markdown: false) }
                    Button("Export Markdown comparison") { export(entry, markdown: true) }
                    if let url = model.history.audioURL(entry) { Button("Share original audio") { sharedItems = [url]; sharing = true } }
                }.disabled(disabled)
            }
        }
        .navigationTitle("Recording")
        .sheet(isPresented: $sharing) { ActivityShareView(items: sharedItems) }
        .confirmationDialog("Permanently delete audio? Text and comparisons will remain.", isPresented: $deleteAudio) {
            Button("Delete audio", role: .destructive) { if let entry { model.history.delete(entry, audioOnly: true) } }
        }
        .onDisappear { model.history.stopPlayback() }
    }
    private func run(_ entry: TranscriptHistoryEntry) {
        model.history.compare(entry, engine: .parakeetStreaming, cleanup: model.selectedPostProcessorID,
            instructions: model.customCleanupInstructions, vocabulary: model.customWordsEnabled ? model.customWordsText : "")
    }
    private func export(_ entry: TranscriptHistoryEntry, markdown: Bool) {
        do { sharedItems = [try model.history.export(entry, markdown: markdown)]; sharing = true }
        catch { model.history.message = error.localizedDescription }
    }
}

struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
