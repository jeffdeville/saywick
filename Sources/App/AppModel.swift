@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import VoiceKeyboardCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    enum RecordingKind: String { case dictation, meeting }
    private(set) var recordingKind: RecordingKind = .dictation
    var isMeetingRecording: Bool { recordingKind == .meeting && (phase == .preparing || phase == .listening || phase == .finalizing) }
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTask: Task<Void, Never>?

    // Intent and UI share one recorder, even on a launch without a scene.
    func startServices() async {
        if startupTask == nil {
            startupTask = Task { await recordingActivity.removeOrphanedActivities() }
        }
        await startupTask?.value
        if commandTask == nil { commandTask = Task { await monitorKeyboardCommands() } }
        if interruptionTask == nil { interruptionTask = Task { await watchInterruptions() } }
    }

    func prepareBackgroundDictation() async {
        guard !isBusy, !history.isWorking, !isKeyboardSessionActive else { return }
        isPreparingBackground = true
        defer { isPreparingBackground = false }
        do {
            guard await microphoneIsAuthorized() else { throw SpeechEngineError.microphoneDenied }
            statusMessage = "Downloading and verifying Parakeet for background dictation…"
            _ = try await ParakeetModelStore.shared.modelURL()
            statusMessage = "Setup complete. Use Start dictation in Shortcuts. Saywick opens when the microphone needs activation."
        } catch { statusMessage = error.localizedDescription }
    }

    var canStartDictationInBackground: Bool {
        MicrophoneCapture.shared.isRunning && isKeyboardSessionActive &&
            (keyboardSessionExpiresAt.map { $0 > Date() } ?? true)
    }

    func startFromShortcut(kind: RecordingKind) async throws {
        await startServices()
        guard !isBusy, !history.isWorking else {
            throw SpeechEngineError.unavailable("A recording or transcription is already in progress. Stop it before starting another.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SpeechEngineError.unavailable("Open Saywick and allow microphone access before using background recording.")
        }
        ActivationDiagnostics.shared.record(kind == .meeting ? "Background meeting intent invoked" : "Background dictation intent invoked")
        await startRecording(kind: kind, fromIntent: true)
        guard phase == .listening else { throw SpeechEngineError.unavailable(statusMessage) }
    }

    func stopFromShortcut() async throws {
        await startServices()
        guard phase == .listening || isKeyboardSessionActive else {
            throw SpeechEngineError.unavailable("No active recording. Start Saywick dictation or a meeting first.")
        }
        // A Stop shortcut also releases idle readiness, unlike Stop & Insert.
        await endKeyboardSession(message: "Microphone off — recording saved in History")
        if phase == .failed { throw SpeechEngineError.unavailable(statusMessage) }
    }

    var history = HistoryModel()
    var selectedTab = 0
    var keepKeyboardReady: Bool {
        didSet { defaults.set(keepKeyboardReady, forKey: "keepKeyboardReady") }
    }
    private(set) var keyboardSessionExpiresAt: Date?
    private(set) var isKeyboardSessionActive = false
    private var endingSession = false
    private var pendingAutoInsert = false
    private var operationID = UUID()
    private var lastHeartbeat = Date.distantPast
    var recordingStartedAt: Date?
    private var keyboardLifecycle: KeyboardRecordingLifecycle?
    @ObservationIgnored private let recordingActivity = RecordingActivity()
    private var originalText = ""
    private var latestPartial = ""
    private var failureCleanup = false
    private var isPreparingBackground = false
    private var resettingTranscript = false
    private var appliedCleanup: PostProcessorID?
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

    let selectedEngineID: SpeechEngineID = .parakeetStreaming
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
        self.keepKeyboardReady = defaults.object(forKey: "keepKeyboardReady") == nil
            ? true : defaults.bool(forKey: "keepKeyboardReady")
        ActivationDiagnostics.shared.record(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? "Process started under Xcode tests" : "App process started")
        self.customWordsText = defaults.string(forKey: "customWords") ?? ""
        self.customWordsEnabled = defaults.object(forKey: "customWordsEnabled") == nil
            ? true : defaults.bool(forKey: "customWordsEnabled")
        // Old engine identifiers remain decodable in History, but all new audio uses Parakeet.
        defaults.set(SpeechEngineID.parakeetStreaming.rawValue, forKey: Keys.engine)
        self.selectedPostProcessorID = PostProcessorID(
            rawValue: defaults.string(forKey: Keys.processor) ?? ""
        ) ?? .foundationModels
        self.customCleanupInstructions = defaults.string(
            forKey: Keys.cleanupInstructions
        ) ?? "Preserve my wording. Pauses may mean I am thinking, not starting a new sentence."
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
        if failureCleanup || endingSession || isPreparingBackground { return true }
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

    func startRecording(kind: RecordingKind = .dictation, fromIntent: Bool = false) async {
        guard !isBusy, !history.isWorking else { return }
        if let expiry = keyboardSessionExpiresAt, expiry <= Date() {
            await endKeyboardSession(message: "Session expired — activate again in Saywick")
        }
        if kind == .dictation, let customWordsError {
            fail(with: SpeechEngineError.unavailable(customWordsError))
            return
        }

        if kind == .meeting, isKeyboardSessionActive {
            await endKeyboardSession()
        }
        recordingKind = kind
        operationID = UUID()
        let operation = operationID
        pendingAutoInsert = false
        sessionID = UUID()
        revision = 0
        accumulator.reset()
        originalText = ""; latestPartial = ""
        appliedCleanup = nil
        processedText = ""
        preparationProgress = nil
        keyboardSessionExpiresAt = nil
        phase = .preparing
        statusMessage = kind == .meeting ? "Preparing meeting recording…" : "Preparing Parakeet…"

        keyboardLifecycle = KeyboardRecordingLifecycle(startedAt: Date())
        let engine = LiveSpeechEngineFactory.make(allowModelDownload: !fromIntent, meeting: kind == .meeting)
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
            if engine.requiresMicrophoneAuthorization {
                guard await microphoneIsAuthorized() else { throw SpeechEngineError.microphoneDenied }
            }
            guard operationID == operation, phase == .preparing else { return }
            // AudioRecordingIntent requires a Live Activity before audio begins.
            // LiveActivityIntent permits requesting it while backgrounded.
            try recordingActivity.start(engine: kind == .meeting ? "Meeting · audio saved locally" : selectedEngineID.displayName,
                                        phase: "Preparing", required: fromIntent)
            engine.archiveURL = try history.begin(id: sessionID, meeting: kind == .meeting)
            try await engine.prepare()
            guard operationID == operation, phase == .preparing else { return }
            if kind == .dictation, keepKeyboardReady, !isKeyboardSessionActive, engine.requiresMicrophoneAuthorization {
                try MicrophoneCapture.shared.beginSession()
                isKeyboardSessionActive = true
            }
            try await engine.start()
            guard operationID == operation, phase == .preparing else { return }
            phase = .listening
            let startedAt = Date()
            recordingStartedAt = startedAt
            await recordingActivity.update(phase: kind == .meeting ? "Recording meeting" : "Recording")
            guard operationID == operation, phase == .listening else { return }
            statusMessage = kind == .meeting ? "Recording meeting — audio stays on this iPhone. Stop when finished." : "Listening — leave this recording active when switching apps"
            publishSnapshot()
        } catch {
            guard operationID == operation else { return }
            fail(with: error)
        }
    }

    func stopRecording(shouldAutoInsert: Bool = false) async {
        guard phase == .listening else { return }
        let operation = operationID
        phase = .finalizing
        if isKeyboardSessionActive { await recordingActivity.update(phase: "Finishing · microphone active") }
        else { await recordingActivity.update(phase: "Finishing") }
        statusMessage = "Finalizing transcript…"
        publishSnapshot()

        do {
            try await engine?.stop()
            await updateTask?.value
            guard phase != .failed, operationID == operation else { return }
            if recordingKind == .meeting {
                try history.completeMeeting(id: sessionID)
                history.activeID = nil
                recordingStartedAt = nil
                engine = nil
                updateTask = nil
                phase = .ready
                statusMessage = "Meeting saved — transcribe it in History"
                await recordingActivity.finish()
                publishSnapshot()
                return
            }
            let vocabulary = try CustomVocabulary(customWordsEnabled ? customWordsText : "")
            let rawText = vocabulary.apply(to: accumulator.finalizedText)
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
                if selectedPostProcessorID.usesLanguageModel {
                    processedText = RuleBasedCleaner.clean(rawText)
                    appliedCleanup = .rules
                    statusMessage = "Used basic cleanup: \(error.localizedDescription)"
                } else {
                    throw error
                }
            }

            guard phase != .failed, operationID == operation else { return }
            // Apply once, after optional cleanup, so replacement chains cannot cascade.
            // Vocabulary was applied before cleanup; never cascade corrections.

            saveHistory(status: "Ready")
            history.activeID = nil
            recordingStartedAt = nil
            if statusMessage == processingMessage {
                statusMessage = processedText.isEmpty ? "No speech detected" : "Ready to insert"
            }
            if isKeyboardSessionActive {
                keyboardSessionExpiresAt = KeyboardReadiness.deadline(after: Date())
                statusMessage += " · Ready for 2 minutes"
                await recordingActivity.update(phase: "Ready · microphone active")
            }
            if !isKeyboardSessionActive { await recordingActivity.finish() }
            engine = nil
            updateTask?.cancel()
            updateTask = nil
            phase = .ready
            publishSnapshot(shouldAutoInsert: shouldAutoInsert)
        } catch {
            guard operationID == operation else { return }
            fail(with: error)
        }
    }

    func clear() {
        guard phase != .preparing, phase != .finalizing else { return }
        if phase == .listening {
            guard recordingKind == .dictation else { return }
            Task { await resetListeningTranscript() }
            return
        }
        pendingAutoInsert = false
        sessionID = UUID()
        revision = 0
        accumulator.reset()
        originalText = ""; latestPartial = ""
        processedText = ""
        if phase == .listening {
            statusMessage = "Listening — transcript cleared"
        } else {
            phase = .idle
            statusMessage = isKeyboardSessionActive ? "Ready to dictate · microphone active" : "Ready"
        }
        publishSnapshot()
    }

    func restartTranscript() {
        guard phase == .listening, recordingKind == .dictation else { return }
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
        pendingAutoInsert = false
        sessionID = UUID()
        revision = 0
        accumulator.reset()
        originalText = ""; latestPartial = ""
        processedText = ""
        phase = .listening
        statusMessage = "Listening — started a new transcript"
        saveHistory(status: "Recording — restarted")
        publishSnapshot()
    }

    func endKeyboardSession(message: String = "Session ended — open Saywick to activate again") async {
        guard !endingSession else { return }
        endingSession = true
        defer { endingSession = false }
        keyboardSessionExpiresAt = nil
        isKeyboardSessionActive = false
        MicrophoneCapture.shared.endSession()
        if phase == .listening { await stopRecording() }
        else if phase == .preparing {
            fail(with: SpeechEngineError.unavailable(message))
        }
        await recordingActivity.finish()
        if phase != .finalizing && phase != .failed { statusMessage = message }
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
        await startServices()
        if url.isFileURL {
            ActivationDiagnostics.shared.record("Audio file opened")
            guard !isBusy else { return }
            selectedTab = 1; history.importAudio(url); return
        }
        guard url.scheme == "localvoicekeyboard" || url.scheme == "saywick" else { return }
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "source" }?.value
        switch source {
        case "keyboard": ActivationDiagnostics.shared.record("Recorder URL received from keyboard link")
        case "liveActivity": ActivationDiagnostics.shared.record("Recorder URL received from Live Activity link")
        default: ActivationDiagnostics.shared.record("Saywick URL received (source unspecified)")
        }
        if url.host == "start" {
            selectedTab = 0
            await startRecording()
        } else if url.host == "history" {
            selectedTab = 1
        } else if url.host == "recorder" {
            selectedTab = 0
        }
    }

    func removeOrphanedRecordingActivities() async {
        await recordingActivity.removeOrphanedActivities()
    }

    func monitorKeyboardCommands() async {
        while !Task.isCancelled {
            if !isKeyboardSessionActive, isBusy, Date().timeIntervalSince(lastHeartbeat) >= 1 {
                lastHeartbeat = Date()
                publishSnapshot()
            }
            if isKeyboardSessionActive {
                if KeyboardReadiness.hasExpired(deadline: keyboardSessionExpiresAt, at: Date()) {
                    await endKeyboardSession(message: "Microphone off after 2 minutes idle — activate again in Saywick")
                } else if !MicrophoneCapture.shared.isRunning {
                    await endKeyboardSession(message: "Microphone interrupted — activate again in Saywick")
                } else if Date().timeIntervalSince(lastHeartbeat) >= 1 {
                    lastHeartbeat = Date()
                    publishSnapshot()
                }
            }
            if recordingKind == .meeting, phase == .listening {
                if engine?.requiresMicrophoneAuthorization == true, !MicrophoneCapture.shared.isRunning {
                    await endKeyboardSession(message: "Meeting interrupted — check the saved audio in History")
                } else if let recordingStartedAt, Date().timeIntervalSince(recordingStartedAt) >= RecordingLimits.maximumDuration {
                    await endKeyboardSession(message: "Meeting reached 4 hours — audio saved in History")
                } else if Date().timeIntervalSince(lastHeartbeat) >= 1 {
                    lastHeartbeat = Date()
                    publishSnapshot()
                }
            }
            if UIApplication.shared.applicationState == .active,
               let action = ShortcutRequests.consume(from: defaults) {
                switch action {
                case .start:
                    selectedTab = 0
                    Task { await startRecording() }
                case .history:
                    selectedTab = 1
                }
            }
            if let command = try? sharedStore?.readCommand(),
               command.id != lastCommandID {
                lastCommandID = command.id
                guard abs(Date().timeIntervalSince(command.issuedAt)) < 10,
                      command.sessionID == nil || command.sessionID == sessionID else { continue }
                switch command.kind {
                case .start:
                    if isKeyboardSessionActive, phase == .idle || phase == .ready {
                        Task { await startRecording() }
                    }
                case .endSession:
                    await endKeyboardSession()
                case .stop:
                    Task { await stopRecording() }
                case .stopAndInsert:
                    Task { await stopRecording(shouldAutoInsert: true) }
                case .restart:
                    restartTranscript()
                case .clear:
                    clear()
                }
            }

            if recordingKind == .dictation, !isKeyboardSessionActive, phase == .listening,
               keyboardLifecycle?.shouldStop(
                presence: try? sharedStore?.readKeyboardPresence(), now: Date()) == true {
                await stopRecording()
                if phase == .ready, appliedCleanup == selectedPostProcessorID {
                    statusMessage = "Keyboard dismissed; transcript saved in History"
                    publishSnapshot()
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func handle(_ update: SpeechEngineUpdate) {
        guard phase == .preparing || phase == .listening || phase == .finalizing else { return }
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
        case .start, .endSession:
            break // These actions are available only through explicit UI controls.
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
        let failure = error as NSError
        ActivationDiagnostics.shared.record("Recording failed: \(failure.domain)/\(failure.code)")
        operationID = UUID()
        keyboardSessionExpiresAt = nil
        isKeyboardSessionActive = false
        pendingAutoInsert = false
        MicrophoneCapture.shared.endSession()
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
            try? await failedEngine?.stop()
            failureCleanup = false
        }
    }

    private func publishSnapshot(shouldAutoInsert: Bool? = nil) {
        if let shouldAutoInsert { pendingAutoInsert = shouldAutoInsert }
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
            shouldAutoInsert: pendingAutoInsert,
            updatedAt: Date(),
            keyboardSessionExpiresAt: keyboardSessionExpiresAt,
            keyboardSessionActive: isKeyboardSessionActive,
            isMeeting: recordingKind == .meeting
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
        guard recordingKind == .dictation else {
            try? history.completeMeeting(id: id, status: status)
            return
        }
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
        pendingAutoInsert = false
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
        for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { continue }
            if isKeyboardSessionActive || phase == .listening || phase == .preparing {
                await endKeyboardSession(message: "Audio interrupted — check History and activate Saywick again")
            }
        }
    }
}
