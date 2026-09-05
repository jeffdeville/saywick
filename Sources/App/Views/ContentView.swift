import SwiftUI
import VoiceKeyboardCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
        NavigationStack {
            Form {
                statusSection
                controlsSection
                transcriptSection
                modelSection
                customWordsSection
                if model.selectedEngineID.isCloud {
                    azureSection
                }
                metricsSection
                keyboardSection
                privacySection
            }
            .navigationTitle("Saywick")
        }
        .tabItem { Label("Dictate", systemImage: "mic") }.tag(0)
        HistoryView(model: model).tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(1)
        }
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
            if model.canStop {
                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Label(model.selectedEngineID.isCloud ? "Stop and transcribe" : "Stop and clean up", systemImage: "stop.circle.fill")
                }

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
                .disabled(model.isBusy || model.isTestingAzure || model.history.isWorking)
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
        Section("Transcript") {
            Text(resultText.isEmpty ? "Your live transcript will appear here." : resultText)
                .foregroundStyle(resultText.isEmpty ? .secondary : .primary)
                .accessibilityIdentifier("transcriptText")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)

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
            Picker("Maximum recording", selection: $model.recordingLimitMinutes) {
                Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("25 minutes").tag(25)
            }.disabled(model.isBusy)
            Picker("Speech engine", selection: $model.selectedEngineID) {
                ForEach(SpeechEngineID.allCases) { engine in
                    VStack(alignment: .leading) {
                        Text(engine.displayName)
                        Text(engine.detail)
                    }
                    .tag(engine)
                }
            }
            .disabled(model.isBusy)

            if model.selectedEngineID == .maiVoiceLive {
                Text("Streams audio to Microsoft as you speak. Uses the mai-transcribe preview alias; Microsoft does not identify its model version. Assistant replies are disabled. Voice Live token pricing applies.")
                    .font(.caption)
            } else if model.selectedEngineID == .maiTranscribe2 {
                Text("Tap Stop for Microsoft’s clean transcript, followed by your local text preferences. Live text and spoken commands are unavailable in this mode.")
                    .font(.caption)
            }
            Picker("Cleanup", selection: $model.selectedPostProcessorID) {
                ForEach(PostProcessorID.allCases) { processor in
                    Text(processor.displayName).tag(processor)
                }
            }
            .disabled(model.isBusy)

            if model.selectedPostProcessorID == .foundationModels {
                TextField(
                    "Cleanup preference",
                    text: $model.customCleanupInstructions,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .disabled(model.isBusy)
            }
        }
    }

    private var customWordsSection: some View {
        Section("Custom words") {
            Toggle("Apply custom words", isOn: $model.customWordsEnabled)
            TextField("Heard spelling = preferred spelling", text: $model.customWordsText, axis: .vertical)
                .lineLimit(3...10)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("customWordsEditor")
            Text("One entry per line: Brecken = Breccan. A word by itself enforces its capitalization. Changes save automatically and apply to final text, not live partials. Exact whole words/phrases only; no fuzzy matching. These corrections stay on your phone.")
                .font(.caption)
            if let error = model.customWordsError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Text("Cleanup is optional and runs on device. Raw transcript keeps the recognizer’s wording plus your custom-word corrections. Apple Foundation Models can rewrite wording; compare its results before relying on it.")
                .font(.caption)
        }
        .disabled(model.isBusy)
    }

    private var azureSection: some View {
        Section("Azure connection") {
            TextField("https://your-resource.cognitiveservices.azure.com/", text: $model.azureEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Azure Speech key", text: $model.azureKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save Azure connection") { model.saveAzureConnection() }
            Button("Test MAI Live connection") {
                Task { await model.testAzureLiveConnection() }
            }
            .disabled(model.isTestingAzure)
            if !model.credentialMessage.isEmpty {
                Text(model.credentialMessage).font(.caption).accessibilityIdentifier("azureConnectionStatus")
            }
            Text("Use Keys and Endpoint from an Azure Speech resource in a region supporting MAI-Transcribe-2. Save before recording.")
                .font(.caption)
        }
        .disabled(model.isBusy || model.isTestingAzure)
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
            Text("1. Install this app from Xcode.\n2. Open Settings > General > Keyboard > Keyboards.\n3. Add Saywick and enable Full Access.\n4. Start listening here, switch to another app, select Saywick, then tap Stop & Insert.")
                .font(.callout)
            Text("For the Action Button: Settings → Action Button → Shortcut → Saywick → Start dictation. The shortcut opens Saywick to activate the microphone. Live recordings stop after 60 seconds without new recognized speech, or at the selected maximum duration.").font(.caption)
            Text(model.history.keepAudio ? "Audio retention is ON: recordings are kept locally for model comparisons. Manage expiry and deletion in History." : "Audio retention is OFF for new dictations. Text history is still saved.").font(.caption)

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
            if model.selectedEngineID == .maiVoiceLive {
                Label("Audio streams to Microsoft Azure while listening. Retention is controlled in History.", systemImage: "cloud")
            } else if model.selectedEngineID == .maiTranscribe2 {
                Label("Recordings are sent to Microsoft Azure when you tap Stop. No additional cleanup service is used.", systemImage: "cloud")
                Text("Audio stays locally when retention is enabled in History; otherwise temporary audio is deleted after the attempt. Your API key stays in this app’s Keychain.")
                    .font(.caption)
            } else {
                Label("Audio and text stay on this iPhone after the selected model’s one-time download.", systemImage: "lock.shield")
            }
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
