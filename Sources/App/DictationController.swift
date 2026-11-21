@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import VoiceKeyboardCore

struct DictationOptions: Sendable {
    var keepReady = true
    var processor: PostProcessorID = .none
    var instructions = ""
    var vocabulary = ""
}

/// Single owner of recording transitions and hardware lifetime. UI is a client.
@MainActor @Observable
final class DictationController {
    @MainActor struct Dependencies {
        var makeEngine: (Bool) -> any LiveSpeechEngine = { LiveSpeechEngineFactory.make(allowModelDownload: $0) }
        var authorize: () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }
        var beginAudio: () throws -> Void = { try MicrophoneCapture.shared.start() }
        var endAudio: () -> Void = { MicrophoneCapture.shared.endSession() }
        var audioRunning: () -> Bool = { MicrophoneCapture.shared.isRunning }
        var sound: () -> Void = { RecordingErrorSound.shared.play() }
        var process: (String, DictationOptions, [String]) async throws -> String = { text, options, words in
            try await TranscriptPostProcessor.process(text, using: options.processor,
                customInstructions: options.instructions, preferredWords: words)
        }
        var applyTemplate: (String, String) async throws -> String = { prompt, text in
            try await TranscriptPostProcessor.applyTemplate(prompt, to: text)
        }
        var cleanupEnabled: () -> Bool? = {
            guard let store = try? SharedContainerStore() else { return nil }
            return try? store.cleanupEnabled()
        }
        var now: () -> Date = Date.init
        var activities = true
    }
    private(set) var session = DictationSession()
    private(set) var statusMessage = "Ready"
    private(set) var processedText = ""
    private(set) var preparationProgress: Double?
    private(set) var sessionID = UUID()
    private(set) var shouldAutoInsert = false
    private(set) var recordingStartedAt: Date?
    private(set) var accumulator = TranscriptAccumulator()
    private(set) var options = DictationOptions()
    var externalCleanupAuthorized: () -> Bool = { false }
    private(set) var activeTemplate: CleanupTemplate?
    private(set) var templateFallback: String?

    private var authorizationGeneration = 0
    private var selectedGeneration = 0
    var authorizedTemplate: CleanupTemplate? {
        selectedGeneration == authorizationGeneration ? activeTemplate : nil
    }

    func revokeTemplateAuthorization() { authorizationGeneration += 1 }

    func selectTemplate(_ template: CleanupTemplate?) {
        selectedGeneration = authorizationGeneration
        activeTemplate = template
    }

    private var appliedProcessor: PostProcessorID = .none
    private var rawText = ""
    private var latestPartial = ""
    private var engine: (any LiveSpeechEngine)?
    private var updates: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private let activity = RecordingActivity()
    private let dependencies: Dependencies
    let history: HistoryModel
    var onChange: (() -> Void)?
    private var deferredEnd = false
    private var keyboardLifecycle: KeyboardRecordingLifecycle?
    private var termination: Task<Void, Never>?

    init(history: HistoryModel, dependencies: Dependencies = Dependencies()) {
        self.history = history; self.dependencies = dependencies
    }
    var isBusy: Bool { session.isBusy }
    var canStop: Bool { session.state == .transcribing && session.pending == nil }
    var isKeyboardSessionActive: Bool { session.ownsMicrophone }
    var keyboardSessionExpiresAt: Date? { session.idleDeadline }
    var transcript: String { accumulator.currentText }
    var finalizedTranscript: String { accumulator.finalizedText }
    var metrics: SpeechMetrics { accumulator.metrics }
    /// Legacy presentation only, never used to drive transitions.
    var phase: SharedSessionPhase {
        if session.pending == .activating || session.pending == .starting { return .preparing }
        if session.pending != nil { return .finalizing }
        switch session.state {
        case .inactive: return session.issue == nil ? (processedText.isEmpty ? .idle : .ready) : .failed
        case .activated: return .ready
        case .transcribing: return .listening
        case .postProcess: return .finalizing
        }
    }
    var canStartInBackground: Bool {
        session.state == .activated && session.pending == nil && dependencies.audioRunning()
            && (session.idleDeadline.map { $0 > dependencies.now() } ?? false)
    }
    private func publish() { onChange?() }
    @discardableResult private func transition(_ event: DictationSession.Event) -> DictationSession.Effect {
        let previous = session.state
        let effect = session.send(event)
        if effect != .rejected {
            ActivationDiagnostics.shared.record("Session \(previous.rawValue) → \(session.state.rawValue); pending \(session.pending?.rawValue ?? "none")")
        }
        return effect
    }
    func start(options: DictationOptions, fromIntent: Bool = false) async {
        guard !isBusy, !history.isWorking else { return }
        if session.idleDeadline.map({ $0 <= dependencies.now() }) == true {
            await end()
        }
        activeTemplate = nil; templateFallback = nil
        self.options = options; appliedProcessor = options.processor
        deferredEnd = false; idleTask?.cancel(); idleTask = nil
        shouldAutoInsert = false; processedText = ""; rawText = ""; latestPartial = ""
        accumulator.reset(); sessionID = UUID(); preparationProgress = nil
        history.stopPlayback(); RecordingErrorSound.shared.stop()
        let engine = dependencies.makeEngine(!fromIntent)
        self.engine = engine
        if session.state == .inactive {
            guard transition(.activate) == .activate else { return }
            let token = session.generation
            statusMessage = "Activating microphone…"; publish()
            do {
                if engine.requiresMicrophoneAuthorization {
                    guard await dependencies.authorize() else { throw SpeechEngineError.microphoneDenied }
                }
                guard token == session.generation else { return }
                if dependencies.activities {
                    try activity.start(engine: "Parakeet", phase: "Preparing", required: fromIntent)
                }
                if engine.requiresMicrophoneAuthorization { try dependencies.beginAudio() }
                transition(.activated(token, dependencies.now()))
            } catch { await fail(error, token: token); return }
        }
        guard transition(.start) == .start else { return }
        let token = session.generation
        statusMessage = "Preparing Parakeet…"; publish()
        updates?.cancel()
        updates = Task { [weak self] in
            for await update in engine.updates {
                guard !Task.isCancelled, let self, self.session.generation == token else { return }
                await self.handle(update, token: token)
            }
        }
        do {
            _ = try CustomVocabulary(options.vocabulary)
            let archiveURL = try await history.beginRecording(id: sessionID, meeting: false)
            guard token == session.generation else { return }
            engine.archiveURL = archiveURL
            try await engine.prepare()
            guard token == session.generation else { return }
            try await engine.start()
            guard token == session.generation else { return }
            transition(.started(token)); recordingStartedAt = dependencies.now()
            keyboardLifecycle = KeyboardRecordingLifecycle(startedAt: dependencies.now())
            statusMessage = "Listening — leave this recording active when switching apps"
            publish()
            if dependencies.activities { await activity.update(phase: "Recording") }
        } catch { await fail(error, token: token) }
    }
    func stop(insert: Bool = false, release: Bool = false) async {
        guard transition(.finish) == .finish else { return }
        let token = session.generation
        let cleanupEnabled = dependencies.cleanupEnabled()
        let template = activeTemplate
        let templateGeneration = selectedGeneration
        activeTemplate = nil
        if let template { options.instructions = template.prompt }
        if template == nil && cleanupEnabled != true {
            options.processor = .none; appliedProcessor = .none
        }
        deferredEnd = release; statusMessage = "Finalizing transcript…"; publish()
        do {
            try await engine?.stop()
            await updates?.value
            guard token == session.generation else { return }
            let vocabulary = try CustomVocabulary(options.vocabulary)
            let text = vocabulary.apply(to: accumulator.finalizedText)
            do {
                let result: String
                if let template {
                    guard templateGeneration == authorizationGeneration, options.processor == .openAILuna, externalCleanupAuthorized() else {
                        throw PostProcessingError.openAIUnavailable
                    }
                    result = try await dependencies.applyTemplate(template.prompt, text)
                } else {
                    result = try await dependencies.process(text, options, vocabulary.preferredWords)
                }
                guard token == session.generation else { return }
                processedText = result
            }
            catch {
                guard token == session.generation else { return }
                DiagnosticLog.error("cleanup.process", error)
                if options.processor.usesLanguageModel, !(error is CancellationError) {
                    processedText = RuleBasedCleaner.clean(text); appliedProcessor = .rules
                    if template != nil { templateFallback = "Template unavailable · local cleanup used" }
                } else { throw error }
            }
            guard token == session.generation else { return }
            try await saveHistory(status: "Ready")
            statusMessage = templateFallback ?? (processedText.isEmpty ? "No speech detected" : (cleanupEnabled == nil ? "Cleanup setting unavailable · cleanup skipped" : (appliedProcessor != options.processor ? "Cleanup unavailable · local rules used" : "Ready to insert")))
            guard token == session.generation else { return }
            let retain = options.keepReady && !deferredEnd && engine?.requiresMicrophoneAuthorization == true
            shouldAutoInsert = insert && !deferredEnd
            history.activeID = nil; recordingStartedAt = nil; engine = nil; updates = nil
            if !retain { dependencies.endAudio() }
            transition(.completed(token, retain: retain, at: dependencies.now()))
            if retain { statusMessage += " · Ready for 2 minutes"; scheduleIdle() }
            publish()
            await updateActivity()
        } catch { await fail(error, token: token) }
    }
    func cancel(restart: Bool = false) async {
        guard transition(.cancel) == .cancel else { return }
        activeTemplate = nil
        idleTask?.cancel(); shouldAutoInsert = false
        let token = session.generation
        let cancelledEngine = engine
        statusMessage = "Cancelling…"; updates?.cancel(); publish()
        await cancelledEngine?.cancel()
        guard token == session.generation else { return }
        do { try await saveHistory(status: "Cancelled") }
        catch { await fail(error, token: token); return }
        let retain = options.keepReady && cancelledEngine?.requiresMicrophoneAuthorization == true
        if !retain { dependencies.endAudio() }
        engine = nil; updates = nil; history.activeID = nil; recordingStartedAt = nil
        accumulator.reset(); rawText = ""; latestPartial = ""; processedText = ""
        transition(.settled(token, retain: retain, at: dependencies.now()))
        statusMessage = "Cancelled"; if retain { scheduleIdle() }
        publish(); await updateActivity()
        guard token == session.generation else { return }
        if restart { await start(options: options) }
    }
    func end(message: String = "Session ended — open Saywick to activate again") async {
        if session.state == .postProcess { deferredEnd = true; shouldAutoInsert = false; return }
        if session.pending != nil {
            await interrupt(message: message, audible: false); return
        }
        if canStop { await stop(release: true); return }
        guard transition(.deactivate) == .release else { return }
        let token = session.generation
        idleTask?.cancel(); dependencies.endAudio()
        transition(.settled(token, retain: false, at: dependencies.now()))
        statusMessage = message; publish(); await updateActivity()
    }
    func interrupt(message: String, audible: Bool = true) async {
        if let termination { await termination.value; return }
        guard transition(.failure(message)) == .alert else { return }
        activeTemplate = nil
        let token = session.generation
        let failedEngine = engine
        updates?.cancel(); idleTask?.cancel(); shouldAutoInsert = false
        dependencies.endAudio(); statusMessage = message; publish()
        let background = dependencies.activities ? UIApplication.shared.beginBackgroundTask(withName: "Save interrupted recording") : .invalid
        let task = Task {
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            await failedEngine?.cancel()
            do { try await saveHistory(status: "Interrupted or failed", error: message) }
            catch { DiagnosticLog.error("history.recovery", error); statusMessage += " · Could not save recovery metadata; check retained audio in History." }
            guard token == session.generation else { return }
            engine = nil; updates = nil; history.activeID = nil; recordingStartedAt = nil
            transition(.settled(token, retain: false, at: dependencies.now()))
            if audible { dependencies.sound() }
            if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: statusMessage) }
            publish(); await updateActivity()
        }
        termination = task
        await task.value; termination = nil
    }
    private func fail(_ error: Error, token: UUID) async {
        guard token == session.generation else { return }
        DiagnosticLog.error("recording.failure", error)
        let error = error as NSError
        ActivationDiagnostics.shared.record("Recording error \(error.domain)/\(error.code)")
        await interrupt(message: error.localizedDescription)
    }
    private func handle(_ update: SpeechEngineUpdate, token: UUID) async {
        guard token == session.generation else { return }
        switch update {
        case .preparing(let message, let progress): statusMessage = message; preparationProgress = progress
        case .partial(let text, _): latestPartial = text; accumulator.consume(update)
        case .final(let text, let latency, let time):
            rawText += (rawText.isEmpty ? "" : " ") + text; latestPartial = ""
            if canStop, let command = SpokenVoiceCommandParser.match(in: text) {
                if command.command == .stopAndInsert {
                    accumulator.consume(.final(text: command.transcriptBeforeCommand, endOfUtteranceLatencyMilliseconds: latency, receivedAt: time))
                }
                Task { [weak self] in
                    guard let self, self.session.generation == token else { return }
                    switch command.command {
                    case .stopAndInsert: await self.stop(insert: true)
                    case .restart, .clear: await self.cancel(restart: true)
                    default: break
                    }
                }
                return
            }
            accumulator.consume(update)
            do { try await saveHistory(status: "Recording — recovery checkpoint") }
            catch { await fail(error, token: token); return }
        case .failure(let message): await interrupt(message: message); return
        }
        publish()
    }
    private func saveHistory(status: String, error: String? = nil) async throws {
        guard let id = history.activeID else { return }
        try await history.recordCheckpoint(id: id, run: TranscriptRun(engine: .parakeetStreaming,
            rawText: [rawText, latestPartial].filter { !$0.isEmpty }.joined(separator: " "), finalText: processedText,
            cleanup: appliedProcessor, cleanupInstructions: options.instructions, vocabulary: options.vocabulary,
            elapsedSeconds: recordingStartedAt.map { dependencies.now().timeIntervalSince($0) } ?? 0, error: error), status: status)
    }
    private func scheduleIdle() {
        idleTask?.cancel()
        guard let deadline = session.idleDeadline else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            await self.checkExpiry()
        }
    }
    func checkExpiry() async {
        guard session.state == .activated, let deadline = session.idleDeadline, dependencies.now() >= deadline else { return }
        await end(message: "Microphone off after 2 minutes idle — activate again in Saywick")
    }
    func checkCapture(presence: KeyboardPresence?) async {
        await checkExpiry()
        if session.ownsMicrophone, session.pending == nil, engine?.requiresMicrophoneAuthorization != false,
           !dependencies.audioRunning() {
            await interrupt(message: "Microphone interrupted — check History and activate Saywick again"); return
        }
        if !options.keepReady, canStop,
                  keyboardLifecycle?.shouldStop(presence: presence, now: dependencies.now()) == true {
            await stop()
        }
    }
    func clear() {
        guard !isBusy else { return }
        templateFallback = nil
        shouldAutoInsert = false; processedText = ""; accumulator.reset(); rawText = ""; latestPartial = ""
        sessionID = UUID(); session.send(.clearIssue)
        statusMessage = session.state == .activated ? "Ready to dictate · microphone active" : "Ready"; publish()
    }
    /// Restore only a completed result, never microphone ownership from disk.
    func restoreResult(_ snapshot: SharedSessionSnapshot) {
        let recovered = snapshot.phase == .failed && snapshot.dictation?.pending == nil && !snapshot.insertableText.isEmpty
        guard !isBusy, session.state == .inactive, snapshot.phase == .ready || recovered else { return }
        templateFallback = snapshot.templateFallback
        sessionID = snapshot.sessionID; processedText = snapshot.insertableText
        if recovered {
            _ = session.send(.activate)
            _ = session.send(.failure(snapshot.dictation?.issue ?? "Recording interrupted"))
            _ = session.send(.settled(session.generation, retain: false, at: dependencies.now()))
        }
        shouldAutoInsert = recovered ? false : snapshot.shouldAutoInsert
        statusMessage = recovered ? "Unfinished text recovered — insert it before starting again" : (processedText.isEmpty ? "Ready" : "Ready to insert — activate Saywick for another dictation")
    }
    func restore(_ text: String) {
        guard !isBusy else { return }
        clear(); processedText = text; statusMessage = "Restored from History — ready to insert"; publish()
    }
    private func updateActivity() async {
        guard dependencies.activities else { return }
        if session.state == .activated { await activity.update(phase: "Ready · microphone active") }
        else if session.state == .inactive { await activity.finish() }
    }
    func shutdown() async {
        await interrupt(message: "Service stopped", audible: false)
        idleTask?.cancel(); updates?.cancel(); onChange = nil
    }
}

