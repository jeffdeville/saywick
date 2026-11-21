@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import VoiceKeyboardCore

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    let templates: CleanupTemplates
    let recorder: DictationController
    var history: HistoryModel
    var correctionContext: VocabularyCorrectionContext?
    var correctionError: String?
    var selectedTab = 0
    var recorderNavigation = UUID()
    private(set) var keyboardOrigin = false
    var currentResultSession: UUID? { recorder.currentResultSession }
    private(set) var keyboardVerified: Bool
    var defaultTemplateModel: String {
        didSet { defaults.set(defaultTemplateModel, forKey: "defaultTemplateModel") }
    }
    func showRecorder() { selectedTab = 0; recorderNavigation = UUID() }
    var keepKeyboardReady: Bool { didSet { defaults.set(keepKeyboardReady, forKey: "keepKeyboardReady") } }
    var bridgeMessage = "Checking keyboard bridge…"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var sharedStore: SharedContainerStore?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    private var acknowledgments: [UUID: CommandAcknowledgment] = [:]
    private var acknowledgment: CommandAcknowledgment?
    private var revision = 0
    private let servicesEnabled: Bool
    private var setupTask: Task<Void, Never>?
    private var setupMessage: String?

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
        didSet {
            if oldValue == .openAILuna && selectedPostProcessorID != .openAILuna { recorder.revokeTemplateAuthorization() }
            defaults.set(selectedPostProcessorID.rawValue, forKey: Keys.processor)
            publishSnapshot()
        }
    }
    var customCleanupInstructions: String {
        didSet { defaults.set(customCleanupInstructions, forKey: Keys.cleanupInstructions) }
    }

    private enum Keys {
        static let engine = "selectedEngine"
        static let processor = "selectedPostProcessor"
        static let cleanupInstructions = "cleanupInstructions"
    }

    init(defaults: UserDefaults = .standard, history: HistoryModel? = nil, dependencies: DictationController.Dependencies = .init(), bridge: SharedContainerStore? = nil) {
        self.keyboardVerified = defaults.bool(forKey: "keyboardInsertionVerified")
        self.defaultTemplateModel = defaults.string(forKey: "defaultTemplateModel") ?? TranscriptPostProcessor.standardModel
        self.templates = CleanupTemplates(defaults: defaults)
        self.servicesEnabled = dependencies.activities
        let history = history ?? HistoryModel(defaults: defaults)
        self.history = history
        self.recorder = DictationController(history: history, dependencies: dependencies)
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
        // Undo the temporary release-preparation opt-out once. Preserve later choices.
        if !defaults.bool(forKey: "onDeviceCleanupDefaultV2") {
            if defaults.bool(forKey: "cleanupOptInMigrationV1"),
               defaults.string(forKey: Keys.processor) == PostProcessorID.none.rawValue {
                defaults.set(PostProcessorID.foundationModels.rawValue, forKey: Keys.processor)
            }
            defaults.set(true, forKey: "onDeviceCleanupDefaultV2")
        }
        self.selectedPostProcessorID = PostProcessorID(
            rawValue: defaults.string(forKey: Keys.processor) ?? ""
        ) ?? .foundationModels
        self.customCleanupInstructions = defaults.string(
            forKey: Keys.cleanupInstructions
        ) ?? "Preserve my wording. Pauses may mean I am thinking, not starting a new sentence."
        // Persist explicitly supplied launch defaults too (useful for personal setup).
        defaults.set(customWordsText, forKey: "customWords")

        do {
            self.sharedStore = defaults === UserDefaults.standard ? try bridge ?? SharedContainerStore() : bridge

            if let snapshot = try self.sharedStore?.readSnapshot() {
                let receipt = try self.sharedStore?.readReceipt(snapshot.sessionID)
                recorder.restoreResult(snapshot, showResult: receipt == nil)
            }
            self.bridgeMessage = "Keyboard bridge ready"
        } catch {
            DiagnosticLog.error("bridge.initialize", error)
            self.bridgeMessage = error.localizedDescription
        }
        recorder.externalCleanupAuthorized = { [weak self] in self?.selectedPostProcessorID == .openAILuna }
        recorder.onChange = { [weak self] in self?.publishSnapshot() }
    }

    var phase: SharedSessionPhase { recorder.phase }
    var statusMessage: String { setupMessage ?? recorder.statusMessage }
    var preparationProgress: Double? { recorder.preparationProgress }
    var processedText: String { recorder.processedText }
    var transcript: String { recorder.transcript }
    var finalizedTranscript: String { recorder.finalizedTranscript }
    var metrics: SpeechMetrics { recorder.metrics }
    var isBusy: Bool { recorder.isBusy || setupTask != nil }
    var canStop: Bool { recorder.canStop }
    var isKeyboardSessionActive: Bool { recorder.isKeyboardSessionActive }
    var keyboardSessionExpiresAt: Date? { recorder.keyboardSessionExpiresAt }
    var recordingStartedAt: Date? { recorder.recordingStartedAt }
    var canStartDictationInBackground: Bool { recorder.canStartInBackground }
    private var options: DictationOptions { DictationOptions(keepReady: keepKeyboardReady,
        processor: selectedPostProcessorID, instructions: customCleanupInstructions,
        vocabulary: customWordsEnabled ? customWordsText : "") }

    func startRecording(fromIntent: Bool = false, fromKeyboard: Bool = false) async {
        await startServices()
        guard !isBusy else { return }
        keyboardOrigin = fromKeyboard
        setupMessage = nil
        await recorder.start(options: options, fromIntent: fromIntent)
    }
    func stopRecording(shouldAutoInsert: Bool = false) async { await recorder.stop(insert: shouldAutoInsert) }
    func cancelRecording() async { await recorder.cancel() }
    func restartTranscript() { Task { await recorder.cancel(restart: true) } }
    func clear() { if recorder.canStop { restartTranscript() } else { recorder.clear() } }
    func endKeyboardSession(message: String = "Session ended — open Saywick to activate again", unexpected: Bool = false) async {
        if unexpected { await recorder.interrupt(message: message) }
        else { await recorder.end(message: message) }
    }
    func restoreOutput(_ text: String, entryID: UUID) { guard !history.isWorking else { return }; recorder.restore(text, entryID: entryID); showRecorder() }
    func copyResult() {
        let text = processedText.isEmpty ? finalizedTranscript : processedText
        if !text.isEmpty { UIPasteboard.general.string = text }
    }
    func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    func startServices() async {
        guard servicesEnabled else { return }
        if startupTask == nil { startupTask = Task { await RecordingActivity().removeOrphanedActivities() } }
        await startupTask?.value
        if commandTask == nil { commandTask = Task { await monitorKeyboardCommands() } }
        if observers.isEmpty { installAudioObservers() }
    }
    func prepareBackgroundDictation() async {
        guard !isBusy, !history.isWorking, !isKeyboardSessionActive else { return }
        let task = Task {
            do {
                guard await DictationController.Dependencies().authorize() else { throw SpeechEngineError.microphoneDenied }
                setupMessage = "Downloading and verifying Parakeet for background dictation…"
                _ = try await ParakeetModelStore.shared.modelURL()
                setupMessage = "Setup complete. Use Start dictation in Shortcuts."
            } catch { DiagnosticLog.error("model.setup", error); setupMessage = error.localizedDescription }
        }
        setupTask = task; await task.value; setupTask = nil
    }
    func startFromShortcut() async throws {
        await startServices()
        guard !isBusy, !history.isWorking else { throw SpeechEngineError.unavailable("A recording or transcription is already in progress.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SpeechEngineError.unavailable("Open Saywick and allow microphone access before using background recording.")
        }
        showRecorder()
        await startRecording(fromIntent: true)
        guard recorder.canStop else { throw SpeechEngineError.unavailable(statusMessage) }
    }
    func stopFromShortcut() async throws {
        await startServices()
        guard canStop || isKeyboardSessionActive else { throw SpeechEngineError.unavailable("No active recording.") }
        await recorder.end()
        if let issue = recorder.session.issue { throw SpeechEngineError.unavailable(issue) }
    }
    func monitorKeyboardCommands() async {
        while !Task.isCancelled {
            do { await recorder.checkCapture(presence: try sharedStore?.readKeyboardPresence()) }
            catch { DiagnosticLog.error("bridge.read-presence", error); await recorder.checkCapture(presence: nil) }
            do {
                if let command = try sharedStore?.readCommand(), acknowledgment?.id != command.id { Task { await receive(command) } }
            } catch { DiagnosticLog.error("bridge.read-command", error) }
            if UIApplication.shared.applicationState == .active, let action = ShortcutRequests.consume(from: defaults) {
                if action == .start { showRecorder(); Task { await startRecording() } } else { selectedTab = 1 }
            }
            if !keyboardVerified, !recorder.processedText.isEmpty,
               (try? sharedStore?.readReceipt(recorder.sessionID))?.disposition == .inserted {
                keyboardVerified = true
                defaults.set(true, forKey: "keyboardInsertionVerified")
            }
            if recorder.session.ownsMicrophone || recorder.isBusy { publishSnapshot() }
            try? await Task.sleep(for: .milliseconds(recorder.session.ownsMicrophone || recorder.isBusy ? 250 : 1000))
        }
    }
    func receive(_ command: VoiceCommand) async {
        if let previous = acknowledgments[command.id] {
            if acknowledgment != previous { acknowledgment = previous; publishSnapshot() }
            return
        }
        let rejection: String?
        if abs(Date().timeIntervalSince(command.issuedAt)) >= 10 { rejection = "Command expired. Try again." }
        else if command.sessionID != nil && command.sessionID != recorder.sessionID { rejection = "Recording changed. Try again." }
        else {
            switch command.kind {
            case .selectTemplate:
                rejection = applyTemplateChoice(command)
            case .start: rejection = recorder.session.state == .activated && !isBusy ? nil : "Microphone is not ready."
            case .stop, .stopAndInsert: rejection = canStop ? nil : "No recording to stop."
            case .cancel, .restart: rejection = canStop ? nil : "No dictation to cancel."
            case .clear: rejection = !isBusy ? nil : "Stop or cancel the recording first."
            case .endSession: rejection = recorder.session.ownsMicrophone ? nil : "Microphone is already off."
            }
        }
        let ack = CommandAcknowledgment(id: command.id, rejection: rejection)
        acknowledgments[command.id] = ack; acknowledgment = ack
        if acknowledgments.count > 128 { acknowledgments = [command.id: ack] }
        publishSnapshot()
        guard rejection == nil else { return }
        // Awaited by this command task: only one accepted keyboard command executes at a time.
        // Independent audio observers can still invalidate the recording during any suspension.
        switch command.kind {
        case .selectTemplate: break // Already applied together with its acknowledgment.
        case .start: await startRecording(fromKeyboard: true)
        case .stop: await recorder.stop()
        case .stopAndInsert: await recorder.stop(insert: true)
        case .cancel: await recorder.cancel()
        case .restart: await recorder.cancel(restart: true)
        case .clear: recorder.clear()
        case .endSession: await recorder.end()
        }
    }
    private var allowsTemplateSelection: Bool {
        recorder.canStop && recorder.options.processor == .openAILuna && selectedPostProcessorID == .openAILuna
    }

    private func applyTemplateChoice(_ command: VoiceCommand) -> String? {
        guard command.sessionID == recorder.sessionID, allowsTemplateSelection else {
            return "The recording or cleanup provider changed."
        }
        if let id = command.templateID {
            guard var template = templates.items.first(where: { $0.id == id }) else {
                return "This template is no longer available."
            }
            template.modelID = template.modelID ?? defaultTemplateModel
            recorder.selectTemplate(template)
        } else {
            recorder.selectTemplate(nil)
        }
        return nil
    }

    private func publishSnapshot() {
        revision += 1
        var snapshot = SharedSessionSnapshot(sessionID: recorder.sessionID, revision: revision, phase: phase,
            engineID: selectedEngineID, finalizedText: finalizedTranscript,
            partialText: recorder.accumulator.partialText, processedText: processedText, message: statusMessage,
            shouldAutoInsert: recorder.shouldAutoInsert, updatedAt: Date(),
            keyboardSessionExpiresAt: keyboardSessionExpiresAt, keyboardSessionActive: isKeyboardSessionActive,
            isMeeting: false)
        snapshot.dictation = recorder.session; snapshot.acknowledgment = acknowledgment
        snapshot.cleanupConfigured = (recorder.canStop ? recorder.options.processor : selectedPostProcessorID) != .none
        if allowsTemplateSelection {
            snapshot.templateChoices = templates.items.map { CleanupTemplateChoice(id: $0.id, name: $0.name) }
            snapshot.selectedTemplate = recorder.authorizedTemplate.map { CleanupTemplateChoice(id: $0.id, name: $0.name) }
        }
        snapshot.templateFallback = recorder.templateFallback
        do { try sharedStore?.write(snapshot: snapshot) }
        catch { DiagnosticLog.error("bridge.publish", error); bridgeMessage = error.localizedDescription }
    }
    private func installAudioObservers() {
        let names: [Notification.Name] = [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            .AVAudioEngineConfigurationChange, AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification]
        for name in names {
            observers.append(Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: name) {
                    guard !Task.isCancelled, let self else { return }
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    let routeReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    await self.audioEvent(name, interruption: raw, routeReason: routeReason)
                }
            })
        }
    }
    func audioEvent(_ name: Notification.Name, interruption: UInt? = nil, routeReason: UInt? = nil) async {
        let capture = MicrophoneCapture.shared
        let audio = AVAudioSession.sharedInstance()
        let ports = audio.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        ActivationDiagnostics.shared.record("Audio event \(name.rawValue); running \(capture.isRunning); rate \(audio.sampleRate); channels \(audio.inputNumberOfChannels); ports \(ports)")
        if name == AVAudioSession.interruptionNotification {
            guard interruption == AVAudioSession.InterruptionType.began.rawValue else { return }
        } else if name == AVAudioSession.routeChangeNotification {
            ActivationDiagnostics.shared.record("Audio route reason \(routeReason ?? 0)")
            guard recorder.session.ownsMicrophone, !capture.isRunning else { return }
        } else if name == .AVAudioEngineConfigurationChange {
            guard recorder.session.ownsMicrophone, !capture.isRunning else { return }
        }
        if name == AVAudioSession.mediaServicesWereResetNotification { capture.resetAfterMediaServicesReset() }
        await recorder.interrupt(message: "Audio interrupted — check History and activate Saywick again")
    }
    func shutdown() async {
        commandTask?.cancel(); commandTask = nil
        observers.forEach { $0.cancel() }; observers = []
        setupTask?.cancel(); await recorder.shutdown()
    }
    func handleOpenURL(_ url: URL) async {
        guard url.scheme == "localvoicekeyboard" || url.scheme == "saywick" else { return }
        await startServices()
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "source" }?.value
        switch source {
        case "keyboard": ActivationDiagnostics.shared.record("Recorder URL received from keyboard link")
        case "liveActivity": ActivationDiagnostics.shared.record("Recorder URL received from Live Activity link")
        default: ActivationDiagnostics.shared.record("Saywick URL received (source unspecified)")
        }
        if url.host == "fix-word" {
            selectedTab = 0
            do {
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
                guard let context = try sharedStore?.readCorrectionContext(), context.id.uuidString == id else {
                    correctionError = "This correction link is no longer current. Tap Fix a word after the latest insertion."
                    return
                }
                do { try sharedStore?.removeCorrectionContext() }
                catch { DiagnosticLog.error("correction.cleanup", error) }
                correctionContext = context
            } catch { correctionError = error.localizedDescription }
        } else if url.host == "start" {
            showRecorder()
            await startRecording(fromKeyboard: source == "keyboard")
        } else if url.host == "history" {
            selectedTab = 1
        } else if url.host == "recorder" {
            showRecorder()
        }
    }

    func addCorrection(heard: String, preferred: String, transcript: String? = nil) throws {
        customWordsText = try CustomVocabulary.addingCorrection(to: customWordsText, heard: heard, preferred: preferred, transcript: transcript)
        customWordsEnabled = true
    }

}
