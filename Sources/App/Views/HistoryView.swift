import SwiftUI
import VoiceKeyboardCore

struct HistoryView: View {
    @Bindable var model: AppModel
    @Binding var path: [UUID]
    @State private var search = ""
    @State private var deleting: TranscriptHistoryEntry?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !model.history.message.isEmpty { Text(model.history.message).font(.caption) }
                if model.history.isWorking { Button("Cancel operation", role: .destructive) { model.history.cancelWork() } }
                if model.history.entries.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Start a dictation to see it here."))
                }
                ForEach(model.history.entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                    || $0.runs.contains { $0.rawText.localizedCaseInsensitiveContains(search) || $0.finalText.localizedCaseInsensitiveContains(search) } }) { entry in
                    NavigationLink(value: entry.id) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).lineLimit(2)
                            Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            if entry.pinned { Label("Pinned", systemImage: "pin").font(.caption) }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = entry }.disabled(model.isBusy || model.history.isWorking)
                        if entry.pinned {
                            Button("Unpin") { model.history.pin(entry) }.tint(.orange).disabled(model.isBusy || model.history.isWorking)
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { HistoryDetailView(model: model, entryID: $0) }
            .navigationTitle("History")
            .searchable(text: $search)
            .confirmationDialog("Permanently delete this recording and every comparison?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete recording and text", role: .destructive) {
                    if let deleting { model.history.delete(deleting) }; deleting = nil
                }
            }
            .onAppear { if !model.isBusy && !model.history.isWorking { model.history.reload() } }
        }
    }
}

private struct HistoryDetailView: View {
    @Bindable var model: AppModel
    let entryID: UUID
    @State private var deleteAudio = false
    @State private var selectedID: UUID?
    @State private var showOriginal: Bool?
    private var entry: TranscriptHistoryEntry? { model.history.entries.first { $0.id == entryID } }
    private var disabled: Bool { model.isBusy || model.history.isWorking }

    private func selectedRun(in entry: TranscriptHistoryEntry) -> TranscriptRun? {
        entry.runs.first { $0.id == selectedID }
            ?? entry.runs.last { !$0.finalText.isEmpty }
            ?? entry.runs.last { !$0.rawText.isEmpty }
            ?? entry.runs.last
    }

    var body: some View {
        Form {
            if let entry {
                Section("Original audio") {
                    if entry.hasAudio {
                        let playing = model.history.playingID == entry.id
                        Button {
                            model.history.play(entry)
                        } label: {
                            Label(playing ? "Stop playback" : "Play original audio", systemImage: playing ? "stop.fill" : "play.fill")
                        }.disabled(disabled)
                    } else {
                        Text("No saved audio").foregroundStyle(.secondary)
                    }
                }
                let run = selectedRun(in: entry)
                if let run {
                    Section {
                        if entry.runs.count > 1 {
                            Picker("Version", selection: Binding(get: { run.id }, set: { selectedID = $0; showOriginal = nil })) {
                                ForEach(Array(entry.runs.enumerated()), id: \.element.id) { index, version in
                                    Text("Version \(index + 1)\(version.error == nil ? "" : " · Incomplete")").tag(version.id)
                                }
                            }
                        }
                        let original = showOriginal ?? run.finalText.isEmpty
                        Picker("Transcript", selection: Binding(get: { original }, set: { showOriginal = $0 })) {
                            Text("Original").tag(true)
                            Text("Final").tag(false)
                        }.pickerStyle(.segmented)
                        let text = original ? run.rawText : run.finalText
                        if !text.isEmpty {
                            Text(text).textSelection(.enabled)
                            CopyHistoryTextButton(title: original ? "Copy original" : "Copy final", text: text)
                                .id(text)
                            Button(original ? "Use original in keyboard" : "Use final in keyboard") {
                                model.restoreOutput(text, entryID: entryID)
                            }.disabled(disabled)
                        } else {
                            Text(original ? "No recognized text" : "No final text").foregroundStyle(.secondary)
                        }
                        if let error = run.error { Text(error).foregroundStyle(.secondary) }
                    }
                }
                if run?.rawText.isEmpty != false && run?.finalText.isEmpty != false {
                    Section {
                        Text("No transcript available")
                        if entry.hasAudio { transcribeButton(entry) }
                    }
                }
                if !model.history.message.isEmpty { Text(model.history.message).font(.footnote) }
                if model.history.isWorking {
                    Button("Cancel operation", role: .destructive) { model.history.cancelWork() }
                }
            }
        }
        .navigationTitle("Recording")
        .toolbar {
            if let entry {
                let run = selectedRun(in: entry)
                if entry.hasAudio || run?.rawText.isEmpty == false || run?.cleanupModelID != nil {
                    Menu {
                        if let modelID = run?.cleanupModelID { Text("Cleanup model: " + modelID) }
                        if entry.hasAudio { transcribeButton(entry) }
                        if let run, !run.rawText.isEmpty {
                            Button(model.selectedPostProcessorID == .openAILuna ? "Reprocess original with OpenAI" : "Reprocess original") {
                                compare(entry, run: run)
                            }.disabled(disabled)
                        }
                        if entry.hasAudio {
                            Button("Delete audio only", role: .destructive) { deleteAudio = true }.disabled(disabled)
                        }
                    } label: { Label("Recording options", systemImage: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Permanently delete audio? The transcript will remain.", isPresented: $deleteAudio) {
            Button("Delete audio", role: .destructive) { if let entry { model.history.delete(entry, audioOnly: true) } }
        }
        .onDisappear { model.history.stopPlayback() }
    }

    private func transcribeButton(_ entry: TranscriptHistoryEntry) -> some View {
        Button(model.selectedPostProcessorID == .openAILuna ? "Transcribe audio with OpenAI cleanup" : "Transcribe audio") {
            compare(entry, run: nil)
        }.accessibilityIdentifier("runComparison").disabled(disabled)
    }

    private func compare(_ entry: TranscriptHistoryEntry, run: TranscriptRun?) {
        selectedID = nil
        showOriginal = nil
        model.history.compare(entry, engine: run?.engine ?? .parakeetStreaming, cleanup: model.selectedPostProcessorID,
            instructions: model.customCleanupInstructions, vocabulary: model.customWordsEnabled ? model.customWordsText : "", reprocess: run)
    }
}

struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct CopyHistoryTextButton: View {
    let title: String
    let text: String
    @State private var copied = false
    @State private var feedbackID = UUID()

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            let id = UUID()
            feedbackID = id
            copied = true
            UIAccessibility.post(notification: .announcement, argument: "Copied")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if feedbackID == id { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
    }
}

struct HistoryStorageSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
                Section("Retention — local, excluded from backups") {
                    Toggle("Keep audio for playback", isOn: $model.history.keepAudio)
                    Picker("Keep unpinned text", selection: $model.history.textDays) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("Forever").tag(0)
                    }
                    Picker("Keep unpinned audio", selection: $model.history.audioDays) {
                        Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("Forever").tag(0)
                    }
                    Text("Expiry is checked when History refreshes or Saywick starts. Previously pinned entries are kept until you unpin or delete them. Turning audio off affects future dictations. Clear resets active dictation, not saved history. Delete is permanent.").font(.caption)
                }.disabled(model.isBusy || model.history.isWorking)
        }.navigationTitle("History storage")
    }
}
