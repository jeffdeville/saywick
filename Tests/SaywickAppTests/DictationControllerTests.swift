import AVFoundation
import XCTest
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor
private final class TestEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .parakeetStreaming
    let requiresMicrophoneAuthorization = true
    var archiveURL: URL?
    let updates: AsyncStream<SpeechEngineUpdate>
    let events: AsyncStream<SpeechEngineUpdate>.Continuation
    var onStop: (() -> Void)?
    var finishes = 0
    var cancels = 0
    var prepareError: Error?
    var prepareGate: CheckedContinuation<Void, Never>?
    var prepareEntered: (() -> Void)?
    var holdPrepare = false
    var cancelGate: CheckedContinuation<Void, Never>?
    var cancelEntered: (() -> Void)?
    var holdCancel = false
    init() { let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self); updates = pair.stream; events = pair.continuation }
    func prepare() async throws {
        events.yield(.preparing(message: "Loading", progress: 0.5))
        if holdPrepare { await withCheckedContinuation { prepareGate = $0; prepareEntered?() } }
        if let prepareError { throw prepareError }
    }
    func start() async throws { events.yield(.partial(text: "hello", receivedAt: Date())) }
    func stop() async throws {
        onStop?()
        finishes += 1
        events.yield(.final(text: "hello world", endOfUtteranceLatencyMilliseconds: 10, receivedAt: Date()))
        events.finish()
    }
    func cancel() async {
        cancels += 1
        if holdCancel { await withCheckedContinuation { cancelGate = $0; cancelEntered?() } }
        events.finish()
    }
}

@MainActor
final class DictationControllerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var history: HistoryModel!
    private var engines: [TestEngine] = []
    private var audio = false
    private var sounds = 0
    private var processing = 0
    private var clock = Date()
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "ControllerTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "keepAudio")
        history = HistoryModel(defaults: defaults, root: root)
        engines = []; audio = false; sounds = 0; processing = 0; clock = Date()
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func dependencies() -> DictationController.Dependencies {
        var d = DictationController.Dependencies()
        d.activities = false
        d.makeEngine = { [unowned self] _ in let e = TestEngine(); engines.append(e); return e }
        d.authorize = { true }
        d.beginAudio = { [unowned self] in audio = true }
        d.endAudio = { [unowned self] in audio = false }
        d.audioRunning = { [unowned self] in audio }
        d.sound = { [unowned self] in sounds += 1 }
        d.process = { [unowned self] text, _, _ in processing += 1; return text.uppercased() }
        d.now = { [unowned self] in clock }
        return d
    }
    func testCleanupSwitchIsSampledAtStop() async {
        var enabled = true
        var used: PostProcessorID?
        var d = dependencies()
        d.cleanupEnabled = { enabled }
        d.process = { text, options, _ in used = options.processor; return text }
        let c = DictationController(history: history, dependencies: d)
        var options = DictationOptions(); options.processor = .openAILuna
        await c.start(options: options)
        enabled = false
        await c.stop(insert: true)
        XCTAssertEqual(used, PostProcessorID.none)
        XCTAssertEqual(history.entries.first?.runs.first?.cleanup, PostProcessorID.none)
        await c.shutdown()
    }
    func testTemplateUsesFullEntryOnceEvenWithPolishOff() async {
        var calls = 0
        var d = dependencies()
        d.cleanupEnabled = { false }
        d.applyTemplate = { prompt, text in
            calls += 1
            XCTAssertEqual(prompt, "Group by day")
            XCTAssertTrue(text.contains("morning"))
            XCTAssertTrue(text.contains("hello world"))
            return "# Journal\nA new day."
        }
        d.process = { text, options, _ in
            XCTAssertEqual(options.processor, PostProcessorID.none)
            return text
        }
        let controller = DictationController(history: history, dependencies: d)
        controller.externalCleanupAuthorized = { true }
        var options = DictationOptions()
        options.processor = .openAILuna
        await controller.start(options: options)
        engines[0].events.yield(.final(text: "morning", endOfUtteranceLatencyMilliseconds: 1, receivedAt: Date()))
        controller.selectTemplate(CleanupTemplate(name: "Journal", prompt: "Group by day"))
        await controller.stop(insert: true)
        XCTAssertEqual(controller.processedText, "# Journal\nA new day.")
        XCTAssertEqual(history.entries.first?.runs.first?.cleanupInstructions, "Group by day")
        await controller.start(options: options)
        await controller.stop()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(controller.activeTemplate)
        await controller.shutdown()
    }

    func testTemplateFallsBackAfterRevocationOrProviderFailure() async throws {
        let catalog = CleanupTemplates(defaults: defaults)
        try catalog.save(CleanupTemplate(name: "Journal", prompt: "Add headings"))
        let template = try XCTUnwrap(CleanupTemplates(defaults: defaults).items.first)
        for revoke in [true, false] {
            var authorized = true
            var requests = 0
            var d = dependencies()
            d.cleanupEnabled = { false }
            d.applyTemplate = { _, _ in
                requests += 1
                throw PostProcessingError.openAIUnavailable
            }
            let c = DictationController(history: history, dependencies: d)
            c.externalCleanupAuthorized = { authorized }
            var options = DictationOptions()
            options.processor = .openAILuna
            await c.start(options: options)
            c.selectTemplate(template)
            engines.last?.onStop = { if revoke { authorized = false } }
            await c.stop(insert: true)
            XCTAssertEqual(requests, revoke ? 0 : 1)
            XCTAssertNotNil(c.templateFallback)
            XCTAssertEqual(c.processedText, "Hello world.")
            let run = try XCTUnwrap(history.entries.first(where: { $0.id == c.sessionID })?.runs.first)
            XCTAssertEqual(run.cleanup, .rules)
            XCTAssertEqual(run.cleanupInstructions, template.prompt)
            XCTAssertTrue(run.rawText.contains("hello world"))
            await c.shutdown()
        }
    }

    func testFinishInsertAndExpiryPreserveResult() async throws {
        let c = DictationController(history: history, dependencies: dependencies())
        await c.start(options: .init())
        XCTAssertEqual(c.session.state, .transcribing); XCTAssertTrue(audio)
        XCTAssertTrue(c.canStop); XCTAssertFalse(c.canStartInBackground)
        await c.stop(insert: true)
        XCTAssertEqual(c.processedText, "HELLO WORLD")
        XCTAssertTrue(c.shouldAutoInsert); XCTAssertEqual(processing, 1)
        XCTAssertEqual(c.session.state, .activated); XCTAssertTrue(c.canStartInBackground)
        XCTAssertEqual(history.entries.first?.runs.first?.finalText, "HELLO WORLD")
        await c.stop(insert: true)
        XCTAssertEqual(engines[0].finishes, 1)
        clock = clock.addingTimeInterval(121); await c.checkExpiry()
        XCTAssertEqual(c.session.state, .inactive); XCTAssertFalse(audio)
        XCTAssertEqual(c.processedText, "HELLO WORLD"); XCTAssertEqual(sounds, 0)
        await c.shutdown()
    }
    func testCancelHasNoFinalizationOrInsertionAndRestartCreatesNewRun() async {
        let c = DictationController(history: history, dependencies: dependencies())
        await c.start(options: .init()); let first = c.sessionID
        await c.cancel(restart: true)
        XCTAssertEqual(engines[0].finishes, 0); XCTAssertEqual(engines[0].cancels, 1)
        XCTAssertEqual(processing, 0); XCTAssertFalse(c.shouldAutoInsert)
        XCTAssertNotEqual(c.sessionID, first); XCTAssertEqual(c.session.state, .transcribing)
        XCTAssertEqual(history.entries.first(where: { $0.id == first })?.status, "Cancelled")
        engines[0].events.yield(.failure(message: "late"))
        await c.cancel()
        XCTAssertEqual(c.session.state, .activated); XCTAssertEqual(sounds, 0)
        await c.shutdown()
    }
    func testPermissionAndSetupFailureReleaseAndSoundOnce() async {
        var d = dependencies(); d.authorize = { false }
        let denied = DictationController(history: history, dependencies: d)
        await denied.start(options: .init())
        XCTAssertEqual(denied.session.state, .inactive); XCTAssertNotNil(denied.session.issue)
        XCTAssertEqual(sounds, 1); XCTAssertFalse(audio)
        await denied.interrupt(message: "Duplicate")
        XCTAssertEqual(sounds, 1)
        var setup = dependencies(); setup.makeEngine = { _ in let e = TestEngine(); e.prepareError = SpeechEngineError.notPrepared; return e }
        let failed = DictationController(history: history, dependencies: setup)
        await failed.start(options: .init())
        XCTAssertEqual(failed.phase, .failed); XCTAssertFalse(failed.isBusy); XCTAssertFalse(audio)
        XCTAssertEqual(sounds, 2)
    }
    func testInterruptionDuringPrepareRejectsLateStart() async {
        var d = dependencies(); let engine = TestEngine(); engine.holdPrepare = true
        let entered = expectation(description: "prepare entered")
        engine.prepareEntered = { entered.fulfill() }; d.makeEngine = { _ in engine }
        let c = DictationController(history: history, dependencies: d)
        let start = Task { await c.start(options: .init()) }
        await fulfillment(of: [entered], timeout: 2)
        await c.interrupt(message: "Car disconnected")
        engine.prepareGate?.resume(); await start.value
        XCTAssertEqual(c.session.state, .inactive); XCTAssertFalse(audio)
        XCTAssertEqual(sounds, 1); XCTAssertFalse(c.shouldAutoInsert)
    }
    func testInterruptionDuringProcessingRejectsLateInsertion() async {
        var d = dependencies(); let entered = expectation(description: "processing entered")
        var finish: CheckedContinuation<String, Never>?
        d.process = { _, _, _ in await withCheckedContinuation { finish = $0; entered.fulfill() } }
        let c = DictationController(history: history, dependencies: d)
        await c.start(options: .init())
        let stop = Task { await c.stop(insert: true) }
        await fulfillment(of: [entered], timeout: 2)
        await c.interrupt(message: "Interrupted")
        finish?.resume(returning: "late text"); await stop.value
        XCTAssertEqual(c.session.state, .inactive); XCTAssertFalse(c.shouldAutoInsert)
        XCTAssertEqual(sounds, 1); XCTAssertFalse(audio)
        XCTAssertTrue(c.processedText.isEmpty, "Late processor output must never become the current result")
    }
    func testStartCannotStealHardwareDuringCancel() async {
        let c = DictationController(history: history, dependencies: dependencies())
        await c.start(options: .init())
        let entered = expectation(description: "cancel entered")
        engines[0].holdCancel = true; engines[0].cancelEntered = { entered.fulfill() }
        let cancellation = Task { await c.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        await c.start(options: .init())
        XCTAssertEqual(engines.count, 1); XCTAssertTrue(c.isBusy)
        engines[0].cancelGate?.resume(); await cancellation.value
        XCTAssertEqual(c.session.state, .activated)
        await c.shutdown()
    }
    func testNoRetentionAndExplicitEndSaveWithoutInsert() async {
        let c = DictationController(history: history, dependencies: dependencies())
        var options = DictationOptions(); options.keepReady = false
        await c.start(options: options); await c.cancel()
        XCTAssertFalse(audio); XCTAssertEqual(c.session.state, .inactive)
        await c.start(options: .init()); await c.end()
        XCTAssertEqual(c.processedText, "HELLO WORLD"); XCTAssertFalse(c.shouldAutoInsert)
        XCTAssertEqual(c.session.state, .inactive); XCTAssertEqual(sounds, 0)
    }
    func testCleanupFallbackAndClearDoesNotExtendLease() async {
        var d = dependencies(); d.process = { _, _, _ in throw SpeechEngineError.notPrepared }
        let c = DictationController(history: history, dependencies: d)
        var o = DictationOptions(); o.processor = .foundationModels
        await c.start(options: o); await c.stop()
        XCTAssertEqual(c.session.state, .activated); XCTAssertEqual(sounds, 0)
        XCTAssertFalse(c.processedText.isEmpty)
        let deadline = c.keyboardSessionExpiresAt
        clock = clock.addingTimeInterval(40); c.clear(); c.restore("restored")
        XCTAssertEqual(c.keyboardSessionExpiresAt, deadline); XCTAssertEqual(c.processedText, "restored")
        await c.shutdown()
    }
    func testCaptureLossAndStorageFailureCannotReportSuccess() async {
        let c = DictationController(history: history, dependencies: dependencies())
        await c.start(options: .init()); audio = false
        await c.checkCapture(presence: nil)
        XCTAssertEqual(c.phase, .failed); XCTAssertEqual(sounds, 1)
        history.store = nil
        await c.start(options: .init())
        XCTAssertEqual(c.phase, .failed); XCTAssertFalse(c.shouldAutoInsert); XCTAssertEqual(sounds, 2)
    }
    func testRelaunchRestoresInterruptedPartialWithoutAutoInsertion() async {
        let c = DictationController(history: history, dependencies: dependencies())
        let snapshot = SharedSessionSnapshot(phase: .failed, partialText: "unfinished words", shouldAutoInsert: true)
        c.restoreResult(snapshot)
        XCTAssertEqual(c.sessionID, snapshot.sessionID)
        XCTAssertEqual(c.processedText, "unfinished words")
        XCTAssertFalse(c.shouldAutoInsert)
        XCTAssertEqual(c.phase, .failed)
        XCTAssertFalse(c.isKeyboardSessionActive)
    }
    func testAppRelaunchPreservesResultIdentityWithoutRestoringMicrophone() async throws {
        let bridge = try LocalVoiceKeyboard.SharedContainerStore(rootURL: root.appendingPathComponent("bridge"))
        let snapshot = SharedSessionSnapshot(phase: .ready, processedText: "saved", shouldAutoInsert: true,
            keyboardSessionExpiresAt: Date().addingTimeInterval(100), keyboardSessionActive: true)
        try bridge.write(snapshot: snapshot)
        let model = AppModel(defaults: defaults, history: history, dependencies: dependencies(), bridge: bridge)
        XCTAssertEqual(model.recorder.sessionID, snapshot.sessionID)
        XCTAssertEqual(model.processedText, "saved")
        XCTAssertTrue(model.recorder.shouldAutoInsert)
        XCTAssertEqual(model.recorder.session.state, .inactive)
        XCTAssertFalse(model.isKeyboardSessionActive)
        await model.receive(.init(kind: .stop, issuedAt: Date().addingTimeInterval(-30)))
        XCTAssertEqual(try bridge.readSnapshot()?.processedText, "saved")
        await model.shutdown()
    }
    func testCommandDeduplicationAndReceiptsDoNotRewriteSnapshot() async throws {
        let bridge = try SharedContainerStore(rootURL: root.appendingPathComponent("bridge"))
        let snapshot = SharedSessionSnapshot(phase: .listening, updatedAt: Date(timeIntervalSince1970: 1000))
        try bridge.write(snapshot: snapshot)
        try bridge.write(receipt: .init(resultID: snapshot.sessionID, disposition: .inserted))
        XCTAssertEqual(try bridge.readSnapshot(), snapshot)
        XCTAssertEqual(try bridge.readReceipt(snapshot.sessionID)?.disposition, .inserted)
        XCTAssertNil(try bridge.readReceipt(UUID()))
        let model = AppModel(defaults: defaults, history: history, dependencies: dependencies())
        await model.startRecording()
        let command = VoiceCommand(kind: .stopAndInsert, sessionID: model.recorder.sessionID)
        await model.receive(command); await model.receive(command)
        XCTAssertEqual(engines[0].finishes, 1); XCTAssertEqual(processing, 1)
        await model.receive(.init(kind: .cancel, issuedAt: Date().addingTimeInterval(-30)))
        XCTAssertEqual(model.recorder.session.state, .activated)
        await model.shutdown()
    }
}
