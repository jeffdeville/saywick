import AVFoundation
import XCTest
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor final class HistoryRecoveryTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var history: HistoryModel!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "HistoryRecovery." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        history = HistoryModel(defaults: defaults, root: root)
    }
    override func tearDown() async throws {
        history.stopPlayback(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func audio(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        memset(buffer.floatChannelData![0], 0, 1600 * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    func testPreviouslyImportedRecordingRemainsAccessibleForHistoryOperations() async throws {
        let legacy = TranscriptHistoryEntry(title: "Existing recording", source: "Imported audio", hasAudio: true)
        try XCTUnwrap(history.store).save(legacy)
        _ = try audio(legacy.id.uuidString + ".wav")
        history.reload()
        XCTAssertFalse(history.isWorking)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.id, legacy.id)
        XCTAssertEqual(entry.source, "Imported audio")
        XCTAssertTrue(entry.hasAudio); XCTAssertNotNil(history.audioURL(entry))
        let original = TranscriptRun(engine: .parakeetStreaming, rawText: "hello world", finalText: "hello world", cleanup: .none)
        history.checkpoint(id: entry.id, run: original, status: "Ready")
        let saved = try XCTUnwrap(history.entries.first)
        history.compare(saved, engine: .parakeetStreaming, cleanup: .rules, instructions: "", vocabulary: "hello = greetings", reprocess: original)
        await history.work?.value
        let updated = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(updated.runs.count, 2)
        XCTAssertEqual(updated.runs.first, original)
        XCTAssertTrue(updated.runs.last!.finalText.lowercased().contains("greetings"))
        let text = try history.export(updated, markdown: false)
        let markdown = try history.export(updated, markdown: true)
        defer { try? FileManager.default.removeItem(at: text); try? FileManager.default.removeItem(at: markdown) }
        XCTAssertFalse(try String(contentsOf: text, encoding: .utf8).isEmpty)
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("hello world"))
        history.pin(updated); XCTAssertTrue(history.entries.first!.pinned)
        history.delete(history.entries.first!, audioOnly: true)
        XCTAssertFalse(history.entries.first!.hasAudio)
        XCTAssertEqual(history.entries.first!.runs.count, 2)
        history.delete(history.entries.first!)
        XCTAssertTrue(history.entries.isEmpty)
    }
    func testFailedReprocessingKeepsOriginalAndNoAudioHasGuidance() async throws {
        history.keepAudio = false
        let id = UUID(); XCTAssertNil(try history.begin(id: id))
        let original = TranscriptRun(engine: .parakeetStreaming, rawText: "hello", finalText: "Hello.", cleanup: .none)
        history.checkpoint(id: id, run: original, status: "Ready"); history.activeID = nil
        let entry = try XCTUnwrap(history.entries.first)
        history.compare(entry, engine: .parakeetStreaming, cleanup: .none, instructions: "", vocabulary: "")
        XCTAssertEqual(history.message, "No retained audio for this entry.")
        history.compare(entry, engine: .parakeetStreaming, cleanup: .rules, instructions: "", vocabulary: "= bad", reprocess: original)
        await history.work?.value
        XCTAssertEqual(history.entries.first?.runs.first, original)
        XCTAssertNotNil(history.entries.first?.runs.last?.error)
        history.play(entry); XCTAssertNil(history.playingID)
    }
    func testActiveRecordingBlocksHistoryWorkAndRetentionPersists() async throws {
        history.keepAudio = false; history.textDays = 10; history.audioDays = 2
        XCTAssertEqual(defaults.integer(forKey: "historyTextDays"), 10)
        XCTAssertEqual(defaults.integer(forKey: "historyAudioDays"), 2)
        XCTAssertFalse(defaults.bool(forKey: "keepAudio"))
        let id = UUID(); _ = try await history.beginRecording(id: id, meeting: false)
        let active = try XCTUnwrap(history.entries.first)
        history.compare(active, engine: .parakeetStreaming, cleanup: .none, instructions: "", vocabulary: "")
        XCTAssertFalse(history.isWorking)
        XCTAssertEqual(history.entries.count, 1)
        try await history.recordCheckpoint(id: id, run: .init(engine: .parakeetStreaming, rawText: "partial", finalText: "", cleanup: .none), status: "Interrupted")
        XCTAssertEqual(history.entries.first?.status, "Interrupted")
        XCTAssertNil(history.audioURL(history.entries.first!))
        do { try await history.recordCheckpoint(id: UUID(), run: .init(engine: .parakeetStreaming, rawText: "", finalText: "", cleanup: .none), status: "Ready"); XCTFail("Missing entry must fail") } catch {}
        let writer = RecordingHistoryWriter()
        do { _ = try await writer.meeting(store: history.store!, id: UUID(), status: "Saved"); XCTFail("Missing meeting must fail") } catch {}
    }
    func testDeletionCannotRemoveRecordingOrComparisonAndMissingDestinationFails() async throws {
        history.keepAudio = false
        let id = UUID(); _ = try history.begin(id: id)
        let entry = try XCTUnwrap(history.entries.first)
        history.activeID = id
        history.delete(entry)
        XCTAssertEqual(history.entries.count, 1)
        history.activeID = nil
        let run = TranscriptRun(engine: .parakeetStreaming, rawText: "hello", finalText: "Hello", cleanup: .none)
        history.compare(entry, engine: .parakeetStreaming, cleanup: .none, instructions: "", vocabulary: "", reprocess: run)
        history.delete(entry)
        XCTAssertEqual(history.entries.count, 1)
        await history.work?.value
        XCTAssertEqual(history.entries.first?.runs.count, 1)
        // Simulate a destination removed outside this UI while a stale entry is open.
        history.delete(history.entries.first!)
        history.compare(entry, engine: .parakeetStreaming, cleanup: .none, instructions: "", vocabulary: "", reprocess: run)
        await history.work?.value
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(history.message.contains("Could not save"))
    }

    func testAudioWorkerConvertsWithoutUIAndProtectedArchiveCloses() async throws {
        let worker = RecordingAudioWorker()
        let archive = root.appendingPathComponent("worker.wav")
        try await worker.open(archive)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for c in 0..<2 { memset(buffer.floatChannelData![c], 0, 4800 * MemoryLayout<Float>.size) }
        let owned = try XCTUnwrap(OwnedAudioBuffer(buffer))
        let samples = try await worker.samples(owned)
        XCTAssertEqual(samples.count, 1600)
        await worker.close()
        XCTAssertEqual(try AVAudioFile(forReading: archive).length, 1600)
        #if !targetEnvironment(simulator)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.path)[.protectionKey] as? FileProtectionType, .completeUnlessOpen)
        #endif
        let recognition = ParakeetWorker()
        do { _ = try await recognition.feed([0]); XCTFail("Unprepared recognition must fail") } catch {}
        let final = try await recognition.finish(); XCTAssertEqual(final, "")
        await recognition.cancel()
    }
}

@MainActor final class AudioLifecycleRegressionTests: XCTestCase {
    func testCancelledNativeEngineCannotInstallConsumerLater() async throws {
        let engine = ParakeetSpeechEngine(allowModelDownload: false)
        await engine.cancel()
        do { try await engine.start(); XCTFail("Cancelled engine restarted") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { try await engine.prepare(); XCTFail("Cancelled engine prepared") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await engine.stop()
    }
    func testErrorSoundCanBeCancelledBeforeOtherPlayback() throws {
        let sound = RecordingErrorSound.shared
        sound.play()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        sound.stop(); sound.stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .spokenAudio)
    }
    func testMediaResetAndDuplicateInterruptionDoNotReactivateMicrophone() async throws {
        let suite = "AudioLifecycle." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var dependencies = DictationController.Dependencies(); dependencies.activities = false
        let model = AppModel(defaults: defaults, history: HistoryModel(defaults: defaults, root: root), dependencies: dependencies)
        await model.audioEvent(AVAudioSession.interruptionNotification, interruption: AVAudioSession.InterruptionType.ended.rawValue)
        await model.audioEvent(AVAudioSession.routeChangeNotification, routeReason: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
        await model.audioEvent(.AVAudioEngineConfigurationChange)
        await model.audioEvent(AVAudioSession.mediaServicesWereResetNotification)
        XCTAssertEqual(model.recorder.session.state, .inactive)
        XCTAssertFalse(MicrophoneCapture.shared.isRunning)
        await model.shutdown()
    }
    func testLocalCleanupAndErrorGuidance() async throws {
        let raw = try await TranscriptPostProcessor.process("hello world", using: .none, customInstructions: "")
        XCTAssertEqual(raw, "hello world")
        let clean = try await TranscriptPostProcessor.process("hello world", using: .rules, customInstructions: "")
        XCTAssertFalse(clean.isEmpty)
        XCTAssertNotNil(PostProcessingError.inputTooLarge.errorDescription)
        XCTAssertNotNil(PostProcessingError.wordingChanged.errorDescription)
        for error in [SpeechEngineError.microphoneDenied, .englishUnavailable, .notPrepared, .unavailable("Unavailable")] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
