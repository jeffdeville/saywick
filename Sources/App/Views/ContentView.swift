import SwiftUI
import VoiceKeyboardCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var openAIKey = ""
    @State private var keyMessage = ""
    @State private var showContactPicker = false
    @State private var pendingContactWords: [String] = []
    @State private var showContactReview = false
    @State private var newWord = ""
    @State private var diagnosticItems: [Any] = []
    @State private var sharingDiagnostics = false
    @State private var diagnosticError: String?

    var body: some View {
        TabView(selection: $model.selectedTab) {
        NavigationStack {
            Form {
                statusSection
                controlsSection
                transcriptSection
                modelSection
                customWordsSection
                metricsSection
                keyboardSection
                privacySection
                #if DEBUG
                Section("App opening diagnostics") {
                    DisclosureGroup("Recent activity") {
                        Text("Records opening links and foreground changes, without transcript contents. iOS does not always identify what brought an app forward.")
                            .font(.caption)
                        ForEach(ActivationDiagnostics.shared.events.reversed()) { event in
                            VStack(alignment: .leading) {
                                Text(event.label)
                                Text(event.date, format: .dateTime.month().day().hour().minute().second())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                #endif
            }
            .navigationTitle("Saywick")
        }
        .tabItem { Label("Dictate", systemImage: "mic") }.tag(0)
        HistoryView(model: model).tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(1)
        }
        .sheet(item: $model.correctionContext) { context in
            CorrectionSheet(model: model, context: context)
        }
        .alert("Could not open correction", isPresented: Binding(get: { model.correctionError != nil }, set: { if !$0 { model.correctionError = nil } })) {
            Button("OK") { model.correctionError = nil }
        } message: { Text(model.correctionError ?? "") }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.phase.displayName)
                        .font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = model.preparationProgress, progress < 1 {
                ProgressView(value: progress)
            }
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle("Keep keyboard ready", isOn: $model.keepKeyboardReady)
                .disabled(model.isBusy || model.isKeyboardSessionActive)
            Text("Activate once, then tap Start Dictation and Stop & Insert in any app using Saywick. The microphone turns off after 2 minutes idle between dictations. Active dictations are not cut short; audio between dictations is discarded.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isKeyboardSessionActive {
                if let expires = model.keyboardSessionExpiresAt {
                    Text("Microphone turns off at \(expires, style: .time)")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("End microphone session", role: .destructive) {
                    Task { await model.endKeyboardSession() }
                }
            }
            if model.canStop {
                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Stop dictation", systemImage: "stop.circle.fill")
                }

                    Button("Cancel dictation", role: .destructive) { Task { await model.cancelRecording() } }
                    Button {
                    model.restartTranscript()
                } label: {
                    Label("Restart transcript", systemImage: "arrow.clockwise.circle")
                }
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Start listening", systemImage: "mic.circle.fill")
                }
                .disabled(model.isBusy || model.history.isWorking)

            }

            Button("Clear", role: .destructive) {
                model.clear()
            }
            .disabled(
                model.phase == .preparing
                    || model.phase == .finalizing
                    || (!model.canStop && model.transcript.isEmpty && model.processedText.isEmpty)
            )
        }
    }

    private var transcriptSection: some View {
        Section(model.phase == .listening ? "Live draft" : "Transcript") {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(resultText.isEmpty ? "Your live draft will appear here. Sentence breaks and capitalization may change after Stop." : resultText)
                            .foregroundStyle(resultText.isEmpty ? .secondary : .primary)
                            .accessibilityIdentifier("transcriptText")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        Color.clear.frame(height: 1).id("transcriptEnd")
                    }
                }
                .frame(height: 120)
                .onChange(of: resultText) { _, _ in reader.scrollTo("transcriptEnd", anchor: .bottom) }
                .onAppear { reader.scrollTo("transcriptEnd", anchor: .bottom) }
            }

            if !model.processedText.isEmpty {
                Button {
                    model.copyResult()
                } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var modelSection: some View {
        Section("Pipeline") {
            LabeledContent("Speech recognition", value: "Parakeet · on device")
            Text("English transcription on this iPhone. First use downloads 731 MB. Live words may revise as you continue; tap Stop to finish. No account or API key is needed.")
                .font(.caption)
            Link("Parakeet by NVIDIA · GGUF by Handy · CC BY 4.0", destination: URL(string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf")!)
                .font(.caption)
            Picker("Post-processing", selection: $model.selectedPostProcessorID) {
                ForEach(PostProcessorID.allCases) { processor in
                    Text(processor.displayName).tag(processor)
                }
            }
            .disabled(model.isBusy)

            Text(model.selectedPostProcessorID == .none
                 ? "Off — inserts the recognizer’s text without AI cleanup. Custom-word replacements still apply."
                 : model.selectedPostProcessorID == .openAILuna ? "After Stop, transcript text is sent to OpenAI for cleanup. This uses your API account and can incur charges." : "Optional cleanup runs locally after Stop and can add a delay.")
                .font(.caption)
            Text("The keyboard Cleanup switch applies to dictations stopped from the keyboard, app, or shortcut. It does not affect History reprocessing.").font(.caption)
            if model.selectedPostProcessorID == .openAILuna {
                NavigationLink("Cleanup templates") { CleanupTemplateSettings(catalog: model.templates) }
                Text("Save prompts for formatting or rewriting a dictation with OpenAI.")
                    .font(.caption)
                SecureField("OpenAI API key", text: $openAIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save API key") {
                    do { try OpenAIKeyStore.save(openAIKey); openAIKey = ""; keyMessage = "API key saved." }
                    catch { keyMessage = "Could not save API key." }
                }
                Button("Remove API key", role: .destructive) {
                    do { try OpenAIKeyStore.save(""); openAIKey = ""; keyMessage = "API key removed." }
                    catch { keyMessage = "Could not remove API key." }
                }
                Text(keyMessage).font(.caption)
            }
            if model.selectedPostProcessorID.usesLanguageModel {
                Text("Regular Polish runs after Stop. Repairs sentence breaks across thinking pauses while preserving your words. Original text stays in History.")
                    .font(.caption)
                TextField(
                    "Short formatting preference",
                    text: $model.customCleanupInstructions,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .disabled(model.isBusy)
            }
        }
    }

    private func uniqueNewWords(_ words: [String]) -> [String] {
        var seen = Set((try? CustomVocabulary(model.customWordsText).entries.map { $0.heard.lowercased() }) ?? [])
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("=") && !$0.contains("\n") && seen.insert($0.lowercased()).inserted }
            .sorted()
    }
    private func appendWords(_ words: [String]) {
        let additions = uniqueNewWords(words)
        guard !additions.isEmpty else { return }
        model.customWordsText = ([model.customWordsText.trimmingCharacters(in: .whitespacesAndNewlines)] + additions)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var customWordsSection: some View {
        Section("Custom words") {
            Toggle("Apply custom words", isOn: $model.customWordsEnabled)
            HStack {
                TextField("Add a word or phrase", text: $newWord)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add") {
                    appendWords([newWord])
                    newWord = ""
                }.disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Add names from Contacts") { showContactPicker = true }
                .disabled(model.customWordsError != nil)
                .sheet(isPresented: $showContactPicker, onDismiss: {
                    if !pendingContactWords.isEmpty { showContactReview = true }
                }) {
                    ContactWordsPicker { names in pendingContactWords = uniqueNewWords(names) }
                }
                .sheet(isPresented: $showContactReview) {
                    NavigationStack {
                        List(pendingContactWords, id: \.self) { Text($0) }
                            .navigationTitle("Review names")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { pendingContactWords = []; showContactReview = false }
                                }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Add names") {
                                        appendWords(pendingContactWords)
                                        pendingContactWords = []; showContactReview = false
                                    }
                                }
                            }
                    }
                }
            TextField("Your words, one per line", text: $model.customWordsText, axis: .vertical)
                .lineLimit(3...10)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("customWordsEditor")
            Text("Add the correct spelling: Saywick, Breccan, or a company name. Similar spellings and close sound-alikes are corrected locally after Stop. Ambiguous matches are left alone. Names from Contacts are selected and reviewed by you; only names are stored on this phone.")
                .font(.caption)
            DisclosureGroup("Advanced: exact replacements") {
                Text("For persistent errors, enter heard spelling = preferred spelling on one line. Example: Brecken = Breccan. Common words such as may and will are protected from automatic name capitalization; an explicit replacement overrides that protection.")
                    .font(.caption)
            }
            if let error = model.customWordsError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Text("Cleanup is optional; OpenAI cleanup sends transcript text to OpenAI when selected. Raw transcript keeps the recognizer’s wording plus your custom-word corrections. Faithful cleanup repairs punctuation and capitalization after Stop. Paragraphs and bullets are opt-in. Regular Polish rejects edits that add, omit or reorder words. A selected OpenAI template may rewrite or summarize.")
                .font(.caption)
        }
        .disabled(model.isBusy)
    }

    private var metricsSection: some View {
        Section("Live measurements") {
            metricRow("First partial", milliseconds: model.metrics.firstPartialMilliseconds)
            metricRow("First finalized text", milliseconds: model.metrics.firstFinalMilliseconds)
            metricRow("Latest phrase-final latency", milliseconds: model.metrics.latestEndOfUtteranceMilliseconds)
            LabeledContent("Final characters", value: "\(model.metrics.finalizedCharacterCount)")
        }
    }

    private var keyboardSection: some View {
        Section("Keyboard extension") {
            Text("1. Open Settings > General > Keyboard > Keyboards.\n2. Add Saywick. Typing works without Full Access.\n3. Enable Full Access for local dictation.\n4. Start listening here, switch to another app, select Saywick, then tap Stop & Insert.")
                .font(.callout)
            Text("For the Action Button: Settings → Action Button → Shortcut → Saywick → Start dictation. After setup below, the shortcut opens Saywick when the microphone needs activation. While the microphone is ready, dictation can restart in the background. Live Activities must be enabled. With Keep keyboard ready enabled, Stop & Insert finishes a transcript while the microphone stays active. Tap Start Dictation for the next one without leaving your app. End stops the microphone. Hiding the keyboard does not end an active session.").font(.caption)
            Text(model.history.keepAudio ? "Audio retention is ON: recordings are kept locally for playback and retranscription. Manage expiry and deletion in History." : "Audio retention is OFF for new dictations. Text history is still saved.").font(.caption)

            Button("Set up background dictation") {
                Task { await model.prepareBackgroundDictation() }
            }.disabled(model.isBusy || model.history.isWorking || model.isKeyboardSessionActive)
            Text("Setup grants microphone access and downloads Parakeet once. Add Start dictation or Stop recording from Saywick in Shortcuts.")
                .font(.caption)

            Button("Open this app’s Settings") {
                model.openKeyboardSettings()
            }

            Label(model.bridgeMessage, systemImage: "arrow.left.arrow.right.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                    Text("Saywick transcribes recordings on this device. If you select OpenAI cleanup, transcript text and the selected cleanup instructions are sent to OpenAI. Regular Polish may also send relevant custom words using your API key. Other cleanup options run on this device. There are no advertising or analytics SDKs.\n\nThe one-time speech model download connects to Hugging Face and its delivery providers, which receive ordinary connection information such as your IP address.\n\nFull Access lets the keyboard exchange commands and transcripts with Saywick locally. Basic typing works without Full Access. Only names you select and confirm in the Contacts picker are saved as custom words.\n\nHistory stores text and optional audio locally. Retention settings and deletion controls are in History; pinned recordings are exempt from automatic expiry. Previously saved recordings remain until deleted or expired. Copies you export or share are controlled by their destination app.\n\niOS may collect and share system diagnostics according to your Apple privacy settings. Saywick keeps a bounded local diagnostic log and Apple-provided performance/crash reports. You can choose to export these for support. Saywick does not upload diagnostic reports itself.")
                        .padding().textSelection(.enabled)
                }.navigationTitle("Privacy policy")
            }
            Label("Audio stays on this iPhone. OpenAI cleanup sends transcript text when selected.", systemImage: "lock.shield")
            Text("The keyboard extension never opens the microphone. The containing app records and transcribes; the two processes exchange small JSON files in their App Group container.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultText: String {
        model.processedText.isEmpty ? model.transcript : model.processedText
    }

    private var statusSymbol: String {
        switch model.phase {
        case .idle: "checkmark.circle"
        case .preparing: "arrow.down.circle"
        case .listening: "waveform.circle.fill"
        case .finalizing: "wand.and.stars"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .listening: .red
        case .failed: .orange
        case .ready: .green
        default: .accentColor
        }
    }

    @ViewBuilder
    private func metricRow(_ title: String, milliseconds: Double?) -> some View {
        LabeledContent(title, value: milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
    }
}

private extension SharedSessionPhase {
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .listening: "Listening"
        case .finalizing: "Finalizing"
        case .ready: "Ready"
        case .failed: "Needs attention"
        }
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
