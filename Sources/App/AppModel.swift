@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import VoiceKeyboardCore

@MainActor
@Observable
final class AppModel {
    var history = HistoryModel()
    var selectedTab = 0
    var recordingStartedAt: Date?
    var lastSpeechAt = Date()
    var recordingLimitMinutes = 5
    @ObservationIgnored private let recordingActivity = RecordingActivity()
    private var originalText = ""
    private var latestPartial = ""
    private var failureCleanup = false
    private var resettingTranscript = false
    private var appliedCleanup: PostProcessorID?
    var azureEndpoint: String {
        didSet { defaults.set(azureEndpoint, forKey: "azureSpeechEndpoint") }
    }
    var azureKey = ""
    var credentialMessage = ""
    var isTestingAzure = false
    var customWordsText: String {
        didSet { defaults.set(customWordsText, forKey: "customWords") }
    }
    var customWordsEnabled: Bool {
        didSet { defaults.set(customWordsEnabled, forKey: "customWordsEnabled") }
    }
    var customWordsError: String? {
        guard customWordsEnabled else { return nil }
        do { _ = try CustomVocabulary(customWordsText); return nil }
        catch { return error.localizedDescription }
    }

    func testAzureLiveConnection() async {
        guard !isBusy, !isTestingAzure, !history.isWorking else { return }
        isTestingAzure = true
        defer { isTestingAzure = false }
        let probe = MAIVoiceLiveEngine(endpoint: azureEndpoint, key: AzureCredentialStore.read())
        defer { probe.cancel() }
        credentialMessage = "Testing MAI Live connection…"
        do {
            try await probe.prepare()
            credentialMessage = "MAI Live connected; transcription enabled and replies disabled"
        } catch {
            credentialMessage = "Connection test failed: \(error.localizedDescription)"
        }
    }

    func saveAzureConnection() {
        do {
            _ = try MAITranscriptionAPI.endpoint(azureEndpoint)
            try AzureCredentialStore.save(azureKey.trimmingCharacters(in: .whitespacesAndNewlines))
            credentialMessage = azureKey.isEmpty ? "Key removed" : "Connection saved; key stored in Keychain"
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    var selectedEngineID: SpeechEngineID {
        didSet { defaults.set(selectedEngineID.rawValue, forKey: Keys.engine) }
    }
    var selectedPostProcessorID: PostProcessorID {
        didSet { defaults.set(selectedPostProcessorID.rawValue, forKey: Keys.processor) }
    }
    var customCleanupInstructions: String {
        didSet { defaults.set(customCleanupInstructions, forKey: Keys.cleanupInstructions) }
    }

    var phase: SharedSessionPhase = .idle
    var statusMessage = "Ready"
    var preparationProgress: Double?
    var processedText = ""
    var bridgeMessage = "Checking keyboard bridge…"

    @ObservationIgnored private let defaults: UserDefaults
    private var accumulator = TranscriptAccumulator()
    @ObservationIgnored private var engine: (any LiveSpeechEngine)?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var lastCommandID: UUID?
    @ObservationIgnored private var isHandlingSpokenCommand = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var sharedStore: SharedContainerStore?

    private enum Keys {
        static let engine = "selectedEngine"
        static let processor = "selectedPostProcessor"
        static let cleanupInstructions = "cleanupInstructions"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.azureEndpoint = defaults.string(forKey: "azureSpeechEndpoint") ?? ""
        self.azureKey = AzureCredentialStore.read()
        self.customWordsText = defaults.string(forKey: "customWords") ?? ""
        self.customWordsEnabled = defaults.object(forKey: "customWordsEnabled") == nil
            ? true : defaults.bool(forKey: "customWordsEnabled")
        // One-time migration makes the requested MAI-only experiment the default
        // on existing installs too; later engine choices remain persistent.
        if !defaults.bool(forKey: "maiDefaultV1") {
            defaults.set(SpeechEngineID.maiTranscribe2.rawValue, forKey: Keys.engine)
            defaults.set(PostProcessorID.none.rawValue, forKey: Keys.processor)
            defaults.set(true, forKey: "maiDefaultV1")
        }
        self.selectedEngineID = SpeechEngineID(
            rawValue: defaults.string(forKey: Keys.engine) ?? ""
        ) ?? .maiTranscribe2
        self.selectedPostProcessorID = PostProcessorID(
            rawValue: defaults.string(forKey: Keys.processor) ?? ""
        ) ?? .none
        self.customCleanupInstructions = defaults.string(
            forKey: Keys.cleanupInstructions
        ) ?? "Keep the result concise and preserve my wording."
        // Persist explicitly supplied launch defaults too (useful for personal setup).
        defaults.set(customWordsText, forKey: "customWords")

        do {
            self.sharedStore = try SharedContainerStore()
            self.lastCommandID = try self.sharedStore?.readCommand()?.id
            self.bridgeMessage = "Keyboard bridge ready"
        } catch {
            self.bridgeMessage = error.localizedDescription
        }
    }

    var transcript: String { accumulator.currentText }
    var finalizedTranscript: String { accumulator.finalizedText }
    var metrics: SpeechMetrics { accumulator.metrics }

    var isBusy: Bool {
        if failureCleanup || isTestingAzure { return true }
        switch phase {
        case .preparing, .listening, .finalizing:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    var canStop: Bool {
        phase == .listening
    }

    func startRecording() async {
        guard !isBusy, !isTestingAzure, !history.isWorking else { return }
        if let customWordsError {
            fail(with: SpeechEngineError.unavailable(customWordsError))
            return
        }

        sessionID = UUID()
        revision = 0
        accumulator.reset()
        originalText = ""; latestPartial = ""
        appliedCleanup = nil
        processedText = ""
        preparationProgress = nil
        phase = .preparing
        statusMessage = "Preparing \(selectedEngineID.displayName)…"

        let engine = LiveSpeechEngineFactory.make(selectedEngineID)
        self.engine = engine
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            for await update in engine.updates {
                guard !Task.isCancelled else { return }
                self?.handle(update)
            }
        }
        publishSnapshot()

        do {
            engine.archiveURL = try history.begin(id: sessionID)
            try await engine.prepare()
            if engine.requiresMicrophoneAuthorization {
                guard await microphoneIsAuthorized() else {
                    throw SpeechEngineError.microphoneDenied
                }
            }
            try await engine.start()
            phase = .listening
            recordingStartedAt = Date(); lastSpeechAt = Date()
            recordingActivity.start(engine: selectedEngineID.displayName)
            statusMessage = selectedEngineID == .maiTranscribe2
                ? "Recording — tap Stop & Insert for Microsoft’s transcript"
                : "Listening — leave this recording active when switching apps"
            publishSnapshot()
        } catch {
            fail(with: error)
        }
    }

    func stopRecording(shouldAutoInsert: Bool = false) async {
        guard phase == .listening else { return }
        phase = .finalizing
        await recordingActivity.finish()
        statusMessage = "Finalizing transcript…"
        publishSnapshot()

        do {
            try await engine?.stop()
            if engine is MAIVoiceLiveEngine || engine is AppleSpeechAnalyzerEngine || engine is MoonshineSpeechEngine {
                await updateTask?.value
            }
            guard phase != .failed else { return }
            if let text = (engine as? MAISpeechEngine)?.completedTranscript {
                originalText = text
                accumulator.consume(.final(text: text, endOfUtteranceLatencyMilliseconds: nil, receivedAt: Date()))
            }
            let vocabulary = try CustomVocabulary(customWordsEnabled ? customWordsText : "")
            let rawText = (engine as? MAISpeechEngine)?.completedTranscript ?? accumulator.finalizedText
            let processingMessage = "Applying final text preferences on device…"
            appliedCleanup = selectedPostProcessorID
            statusMessage = processingMessage

            do {
                processedText = try await TranscriptPostProcessor.process(
                    rawText,
                    using: selectedPostProcessorID,
                    customInstructions: customCleanupInstructions,
                    preferredWords: vocabulary.preferredWords
                )
            } catch {
                if selectedPostProcessorID == .foundationModels {
                    processedText = RuleBasedCleaner.clean(rawText)
                    appliedCleanup = .rules
                    statusMessage = "Apple Intelligence unavailable; used local rules"
                } else {
                    throw error
                }
            }

            // Apply once, after optional cleanup, so replacement chains cannot cascade.
            processedText = vocabulary.apply(to: processedText)

            phase = .ready
            saveHistory(status: "Ready")
            history.activeID = nil
            recordingStartedAt = nil
            if statusMessage == processingMessage {
                statusMessage = processedText.isEmpty ? "No speech detected" : "Ready to insert"
            }
            publishSnapshot(shouldAutoInsert: shouldAutoInsert)
            engine = nil
            updateTask?.cancel()
            updateTask = nil
        } catch {
            fail(with: error)
        }
    }

    func clear() {
        guard phase != .preparing, phase != .finalizing else { return }
        if phase == .listening {
            Task { await resetListeningTranscript() }
            return
        }
        sessionID = UUID()
        revision = 0
        accumulator.reset()
        originalText = ""; latestPartial = ""
        processedText = ""
        if phase == .listening {
            statusMessage = "Listening — transcript cleared"
        } else {
            phase = .idle
            statusMessage = "Ready"
        }
        publishSnapshot()
    }

    func restartTranscript() {
        guard phase == .listening else { return }
        Task { await resetListeningTranscript() }
    }

    private func resetListeningTranscript() async {
        guard phase == .listening, !resettingTranscript else { return }
        resettingTranscript = true
        phase = .preparing; statusMessage = "Resetting transcript and current audio…"; publishSnapshot()
        defer { resettingTranscript = false }
        do { try await engine?.discardCurrentAudio() }
        catch { fail(with: error); return }
        guard phase != .failed else { return }
        sessionID = UUID()
        revision = 0
        accumulator.reset()
        originalText = ""; latestPartial = ""
        processedText = ""
        phase = .listening
        lastSpeechAt = Date()
        statusMessage = "Listening — started a new transcript"
        saveHistory(status: "Recording — restarted")
        publishSnapshot()
    }

    func copyResult() {
        let value = processedText.isEmpty ? finalizedTranscript : processedText
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        statusMessage = "Copied"
    }

    func openKeyboardSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func handleOpenURL(_ url: URL) async {
        if url.isFileURL {
            guard !isBusy else { return }
            selectedTab = 1; history.importAudio(url); return
        }
        guard url.scheme == "localvoicekeyboard" || url.scheme == "saywick" else { return }
        if url.host == "start" {
            selectedTab = 0
            await startRecording()
        } else if url.host == "history" {
            selectedTab = 1
        } else if url.host == "recorder" {
            selectedTab = 0
        }
    }

    func monitorKeyboardCommands() async {
        while !Task.isCancelled {
            if defaults.bool(forKey: "saywickPendingStart") {
                defaults.set(false, forKey: "saywickPendingStart")
                selectedTab = 0
                await startRecording()
            }
            if defaults.bool(forKey: "saywickPendingHistory") {
                defaults.set(false, forKey: "saywickPendingHistory")
                selectedTab = 1
            }
            if phase == .listening, let recordingStartedAt,
               (Date().timeIntervalSince(recordingStartedAt) > Double(recordingLimitMinutes * 60)
                || Date().timeIntervalSince(lastSpeechAt) > 60 && selectedEngineID != .maiTranscribe2) {
                await stopRecording()
                statusMessage = "Session timed out; transcript saved in History"
                publishSnapshot()
            }
            if let command = try? sharedStore?.readCommand(),
               command.id != lastCommandID {
                lastCommandID = command.id
                switch command.kind {
                case .stop:
                    await stopRecording()
                case .stopAndInsert:
                    await stopRecording(shouldAutoInsert: true)
                case .restart:
                    restartTranscript()
                case .clear:
                    clear()
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func handle(_ update: SpeechEngineUpdate) {
        if resettingTranscript {
            if case .failure(let message) = update { fail(with: SpeechEngineError.unavailable(message)) }
            return
        }
        switch update {
        case .preparing(let message, let progress):
            statusMessage = message
            preparationProgress = progress
        case .final(let text, let latency, let receivedAt):
            originalText += (originalText.isEmpty ? "" : " ") + text
            latestPartial = ""
            if !text.isEmpty { lastSpeechAt = Date() }
            saveHistory(status: "Recording — recovery checkpoint")
            let spokenCommand = SpokenVoiceCommandParser.match(in: text)
            if isHandlingSpokenCommand, spokenCommand != nil {
                // Some engines flush their most recent final again when stop()
                // is called. Never append the command words on that callback.
                return
            }
            if phase == .listening, let command = spokenCommand {
                isHandlingSpokenCommand = true

                // Consuming an empty final also clears the command words from
                // the accumulator's last partial transcription.
                if command.command == .stopAndInsert {
                    accumulator.consume(
                        .final(
                            text: command.transcriptBeforeCommand,
                            endOfUtteranceLatencyMilliseconds: latency,
                            receivedAt: receivedAt
                        )
                    )
                }
                publishSnapshot()

                Task { [weak self] in
                    await self?.performSpokenCommand(command.command)
                }
                return
            }
            accumulator.consume(update)
        case .partial(let text, _):
            if text != latestPartial, !text.isEmpty { lastSpeechAt = Date() }
            latestPartial = text
            accumulator.consume(update)
        case .failure(let message):
            fail(with: SpeechEngineError.unavailable(message))
            return
        }
        publishSnapshot()
    }

    private func performSpokenCommand(_ command: VoiceCommandKind) async {
        defer { isHandlingSpokenCommand = false }
        switch command {
        case .stop:
            await stopRecording()
        case .stopAndInsert:
            await stopRecording(shouldAutoInsert: true)
        case .restart:
            // Keep the active audio session alive so this also works while the
            // containing app is in the background; reset its transcript state.
            restartTranscript()
        case .clear:
            clear()
        }
    }

    private func fail(with error: Error) {
        phase = .failed
        statusMessage = error.localizedDescription
        saveHistory(status: "Interrupted or failed", error: error.localizedDescription)
        history.activeID = nil
        recordingStartedAt = nil
        Task { await recordingActivity.finish() }
        publishSnapshot()
        let failedEngine = engine
        failureCleanup = true
        updateTask?.cancel()
        updateTask = nil
        engine = nil
        Task {
            if let live = failedEngine as? MAIVoiceLiveEngine {
                live.cancel()
            } else if let cloud = failedEngine as? MAISpeechEngine {
                cloud.cancel()
            } else {
                try? await failedEngine?.stop()
            }
            failureCleanup = false
        }
    }

    private func publishSnapshot(shouldAutoInsert: Bool = false) {
        revision += 1
        let snapshot = SharedSessionSnapshot(
            sessionID: sessionID,
            revision: revision,
            phase: phase,
            engineID: selectedEngineID,
            finalizedText: accumulator.finalizedText,
            partialText: accumulator.partialText,
            processedText: processedText,
            message: statusMessage,
            shouldAutoInsert: shouldAutoInsert,
            updatedAt: Date()
        )

        do {
            try sharedStore?.write(snapshot: snapshot)
        } catch {
            bridgeMessage = error.localizedDescription
        }
    }

    private func microphoneIsAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }

    private func saveHistory(status: String, error: String? = nil) {
        guard let id = history.activeID else { return }
        let raw = [originalText, latestPartial].filter { !$0.isEmpty }.joined(separator: " ")
        history.checkpoint(id: id, run: TranscriptRun(engine: selectedEngineID, rawText: raw,
            finalText: processedText, cleanup: appliedCleanup ?? selectedPostProcessorID,
            cleanupInstructions: customCleanupInstructions,
            vocabulary: customWordsEnabled ? customWordsText : "",
            elapsedSeconds: recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0,
            error: error), status: status)
    }

    func restoreOutput(_ text: String) {
        guard !isBusy, !history.isWorking else { return }
        sessionID = UUID(); accumulator.reset(); processedText = text
        phase = .ready; statusMessage = "Restored from History — ready to insert"
        selectedTab = 0; publishSnapshot()
    }

    func addCorrection(heard: String, preferred: String) throws {
        let line = heard.trimmingCharacters(in: .whitespacesAndNewlines) + " = " + preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = customWordsText.isEmpty ? line : customWordsText + "\n" + line
        _ = try CustomVocabulary(updated)
        customWordsText = updated; customWordsEnabled = true
    }

    func watchInterruptions() async {
        for await _ in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
            if phase == .listening {
                await stopRecording()
                statusMessage = "Audio interrupted; check History for your transcript"
                publishSnapshot()
            }
        }
    }
}
