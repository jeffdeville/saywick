import UIKit
import ObjectiveC
import XCTest
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor private final class Document: NSObject, UITextDocumentProxy {
    var text = "existing"
    var hasText: Bool { !text.isEmpty }
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier = UUID()
    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}
@MainActor private final class Keyboard: KeyboardViewController {
    let document = Document()
    override var hasFullAccess: Bool { true }
    override var textDocumentProxy: any UITextDocumentProxy { document }
}
@MainActor final class KeyboardCommandTests: XCTestCase {
    private var root: URL!
    private var bridge: SharedContainerStore!
    private var windows: [UIWindow] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        bridge = try SharedContainerStore(rootURL: root)
    }
    override func tearDown() async throws {
        windows.forEach { $0.rootViewController = nil; $0.isHidden = true }; windows = []
        try? FileManager.default.removeItem(at: root)
    }
    func testCorrectionHandoffLoadsAndSavesForFutureDictations() async throws {
        let suite = "CorrectionHandoffTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var dependencies = DictationController.Dependencies()
        dependencies.activities = false
        let history = HistoryModel(defaults: defaults, root: root.appendingPathComponent("history"))
        let appBridge = try LocalVoiceKeyboard.SharedContainerStore(rootURL: root)
        let model = AppModel(defaults: defaults, history: history, dependencies: dependencies, bridge: appBridge)
        let context = VocabularyCorrectionContext(transcript: "I called Brecken yesterday.")
        try bridge.write(correctionContext: context)
        await model.handleOpenURL(try XCTUnwrap(URL(string: "saywick://fix-word?id=" + context.id.uuidString)))
        XCTAssertEqual(model.correctionContext, context)
        XCTAssertNil(try bridge.readCorrectionContext())
        try model.addCorrection(heard: "Brecken", preferred: "Breccan", transcript: context.transcript)
        XCTAssertEqual(try CustomVocabulary(model.customWordsText).apply(to: "Call Brecken"), "Call Breccan")
    }
    func testCorrectionBridgePreservesExactLatestInsertion() throws {
        let first = VocabularyCorrectionContext(transcript: "Brecken went to new york.")
        try bridge.write(correctionContext: first)
        XCTAssertEqual(try bridge.readCorrectionContext(), first)
        let latest = VocabularyCorrectionContext(transcript: "Use C++.")
        try bridge.write(correctionContext: latest)
        XCTAssertEqual(try bridge.readCorrectionContext(), latest)
        XCTAssertNotEqual(try bridge.readCorrectionContext()?.id, first.id)
        try bridge.removeCorrectionContext()
        XCTAssertNil(try bridge.readCorrectionContext())
    }

    private func keyboard() -> Keyboard {
        let k = Keyboard(); k.store = bridge; k.loadViewIfNeeded()
        show(k)
        return k
    }
    private func show(_ keyboard: Keyboard) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        windows.append(window)
        window.rootViewController = keyboard
        window.makeKeyAndVisible()
        keyboard.viewDidAppear(false)
    }
    private func refresh(_ keyboard: Keyboard) { _ = keyboard.perform(NSSelectorFromString("refreshSnapshot")) }
    private func button(_ title: String, _ view: UIView) throws -> UIButton {
        func matches(_ v: UIView) -> [UIButton] {
            let own = (v as? UIButton).map { button in
                button.configuration?.title == title || button.accessibilityLabel == title ? [button] : []
            } ?? []
            return own + v.subviews.flatMap(matches)
        }
        func visible(_ v: UIView) -> Bool { !v.isHidden && (v.superview.map(visible) ?? true) }
        let candidates = matches(view)
        if let button = candidates.first(where: { visible($0) }) ?? candidates.first { return button }
        throw NSError(domain: "Missing button: " + title, code: 1)
    }
    func testCleanupToggleIsVisibleWhileRecordingAndPersists() throws {
        var snapshot = SharedSessionSnapshot(phase: .listening, updatedAt: Date(), keyboardSessionActive: true)
        snapshot.cleanupConfigured = true
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        let toggle = try button("Polish", k.view)
        var view: UIView? = toggle
        while let current = view { XCTAssertFalse(current.isHidden); view = current.superview }
        toggle.sendActions(for: .touchUpInside)
        XCTAssertFalse(try bridge.cleanupEnabled())
        XCTAssertEqual(try button("Polish", k.view).accessibilityValue, "Off")
    }
    func testTemplateDropdownReturnsToPlainPolishWhenCapabilityDisappears() throws {
        let choice = CleanupTemplateChoice(id: UUID(), name: "Journaling")
        var snapshot = SharedSessionSnapshot(phase: .listening, keyboardSessionActive: true)
        snapshot.cleanupConfigured = true
        snapshot.templateChoices = [choice]
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        try button("Cleanup choices", k.view).sendActions(for: .touchUpInside)
        try button("Journaling", k.view).sendActions(for: .touchUpInside)
        let command = try XCTUnwrap(bridge.readCommand())
        let reopened = keyboard()
        XCTAssertFalse(try button("Stop and insert", reopened.view).isEnabled)
        try button("Stop and insert", reopened.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(try bridge.readCommand()?.id, command.id)
        XCTAssertEqual(command.templateID, choice.id)
        XCTAssertEqual(command.sessionID, snapshot.sessionID)
        snapshot.selectedTemplate = choice
        snapshot.acknowledgment = .init(id: command.id)
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertEqual(try button("Cleanup choices", k.view).accessibilityValue, "Journaling")
        snapshot.templateChoices = nil
        snapshot.selectedTemplate = nil
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertThrowsError(try button("Cleanup choices", k.view))
        try button("Polish", k.view).sendActions(for: .touchUpInside)
        XCTAssertFalse(try bridge.cleanupEnabled())
    }

    func testMultilineInsertionRetainsFallbackDisclosureAfterReceipt() throws {
        let text = "Morning\n\nI walked to work."
        var snapshot = SharedSessionSnapshot(phase: .ready, processedText: text, shouldAutoInsert: true)
        snapshot.templateFallback = "Template unavailable · local cleanup used"
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        refresh(k)
        XCTAssertTrue(k.document.text.hasSuffix(text))
        XCTAssertEqual(try bridge.readReceipt(snapshot.sessionID)?.disposition, .inserted)
        func visibleNotice(_ view: UIView) -> Bool {
            guard !view.isHidden else { return false }
            if let label = view as? UILabel, label.text == snapshot.templateFallback { return true }
            return view.subviews.contains(where: visibleNotice)
        }
        XCTAssertTrue(visibleNotice(k.view))
    }
    func testStartWaitsForExplicitAcknowledgmentAndCancelUsesSameBridge() throws {
        var snapshot = SharedSessionSnapshot(phase: .ready, updatedAt: Date(), keyboardSessionActive: true)
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        try button("Start dictation", k.view).sendActions(for: .touchUpInside)
        let start = try XCTUnwrap(bridge.readCommand())
        XCTAssertEqual(start.kind, .start)
        XCTAssertFalse(try button("Start dictation", k.view).isEnabled)
        snapshot.phase = .listening
        snapshot.acknowledgment = .init(id: start.id)
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertTrue(try button("Stop and insert", k.view).isEnabled)
        try button("Cancel dictation", k.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(try bridge.readCommand()?.kind, .cancel)
        XCTAssertEqual(try bridge.readSnapshot()?.phase, .listening)
    }
    func testInterruptedPartialCanBeInsertedOnce() throws {
        var session = DictationSession()
        _ = session.send(.activate)
        _ = session.send(.activated(session.generation, Date()))
        _ = session.send(.start)
        _ = session.send(.started(session.generation))
        _ = session.send(.failure("Microphone interrupted"))
        var snapshot = SharedSessionSnapshot(phase: .failed, partialText: "unfinished words")
        snapshot.dictation = session
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        XCTAssertTrue(try button("Insert Latest", k.view).isHidden)
        _ = session.send(.settled(session.generation, retain: false, at: Date()))
        snapshot.dictation = session
        try bridge.write(snapshot: snapshot); refresh(k)
        snapshot.partialText = ""
        snapshot.processedText = "unfinished words"
        try bridge.write(snapshot: snapshot); refresh(k)
        func transcript(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityIdentifier == "keyboardTranscript" { return text }
            return view.subviews.compactMap { transcript(in: $0) }.first
        }
        XCTAssertEqual(transcript(in: k.view)?.text, "unfinished words")
        let recover = try button("Insert recovered", k.view)
        XCTAssertTrue(recover.isEnabled)
        recover.sendActions(for: .touchUpInside)
        XCTAssertEqual(k.document.text, "existing unfinished words")
        XCTAssertEqual(try bridge.readReceipt(snapshot.sessionID)?.disposition, .inserted)
        refresh(k)
        XCTAssertTrue(try button("Insert recovered", k.view).isHidden)
        XCTAssertEqual(keyboard().document.text, "existing")
    }
    func testInsertionWaitsForAttachedAppearanceAndSurvivesTwoDictations() throws {
        let first = SharedSessionSnapshot(phase: .ready, processedText: "first", shouldAutoInsert: true)
        try bridge.write(snapshot: first)
        let k = Keyboard(); k.store = bridge; k.loadViewIfNeeded()
        XCTAssertEqual(k.document.text, "existing")
        XCTAssertNil(try bridge.readReceipt(first.sessionID))
        k.viewWillAppear(false); refresh(k)
        XCTAssertNil(try bridge.readReceipt(first.sessionID))
        k.viewDidAppear(false) // Appearance alone is insufficient without attachment.
        XCTAssertNil(try bridge.readReceipt(first.sessionID))
        show(k)
        XCTAssertEqual(k.document.text, "existing first")
        XCTAssertNotNil(try bridge.readReceipt(first.sessionID))
        k.viewWillDisappear(false)
        let second = SharedSessionSnapshot(phase: .ready, processedText: "second", shouldAutoInsert: true)
        try bridge.write(snapshot: second); refresh(k)
        XCTAssertEqual(k.document.text, "existing first")
        XCTAssertNil(try bridge.readReceipt(second.sessionID))
        // A manual insertion must also leave the result available during transition.
        _ = k.perform(NSSelectorFromString("insertLatest"))
        XCTAssertNil(try bridge.readReceipt(second.sessionID))
        k.viewDidAppear(false); refresh(k)
        XCTAssertEqual(k.document.text, "existing first second")
        XCTAssertNotNil(try bridge.readReceipt(second.sessionID))
        refresh(k)
        XCTAssertEqual(k.document.text, "existing first second")
    }

    func testAutoInsertionReceiptSurvivesKeyboardRecreationAndUndo() throws {
        let snapshot = SharedSessionSnapshot(phase: .ready, processedText: "hello", shouldAutoInsert: true)
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        XCTAssertEqual(k.document.text, "existing hello")
        XCTAssertEqual(try bridge.readReceipt(snapshot.sessionID)?.disposition, .inserted)
        refresh(k); XCTAssertEqual(k.document.text, "existing hello")
        let reopened = keyboard(); XCTAssertEqual(reopened.document.text, "existing")
        try button("Undo insertion", k.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(k.document.text, "existing")
        refresh(k); XCTAssertEqual(k.document.text, "existing")
        XCTAssertEqual(try bridge.readSnapshot()?.processedText, "hello")
    }
    func testMissingObjectiveCDocumentIdentifierStillInsertsAndSavesReceipt() throws {
        let getter = try XCTUnwrap(class_getInstanceMethod(Document.self,
            #selector(getter: UITextDocumentProxy.documentIdentifier)))
        let nilID: @convention(block) (AnyObject) -> NSUUID? = { _ in nil }
        let replacement = imp_implementationWithBlock(nilID)
        let original = method_setImplementation(getter, replacement)
        defer { method_setImplementation(getter, original); imp_removeBlock(replacement) }
        let snapshot = SharedSessionSnapshot(phase: .ready, processedText: "hello", shouldAutoInsert: true)
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        XCTAssertEqual(k.document.text, "existing hello")
        XCTAssertEqual(try bridge.readReceipt(snapshot.sessionID)?.disposition, .inserted)
        XCTAssertFalse(try button("Undo insertion", k.view).isEnabled)
        _ = k.perform(NSSelectorFromString("undoInsertion"))
        XCTAssertEqual(k.document.text, "existing hello")
        refresh(k)
        XCTAssertEqual(k.document.text, "existing hello")
    }

    func testUndoRefusesDifferentDocumentWithIdenticalText() throws {
        try bridge.write(snapshot: SharedSessionSnapshot(phase: .ready, processedText: "hello", shouldAutoInsert: true))
        let k = keyboard()
        k.document.documentIdentifier = UUID()
        _ = k.perform(NSSelectorFromString("undoInsertion"))
        XCTAssertEqual(k.document.text, "existing hello")
    }

    func testLiveTranscriptScrollsToNewestTextWithoutResettingUnchangedDraft() throws {
        var snapshot = SharedSessionSnapshot(phase: .listening, partialText: "First words")
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        k.view.frame = CGRect(x: 0, y: 0, width: 393, height: 250)
        func transcript(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityIdentifier == "keyboardTranscript" { return text }
            return view.subviews.compactMap { transcript(in: $0) }.first
        }
        let text = try XCTUnwrap(transcript(in: k.view))
        snapshot.partialText = (1...80).map { "Line \($0) of live transcription" }.joined(separator: "\n")
        try bridge.write(snapshot: snapshot); refresh(k)
        k.view.layoutIfNeeded()
        text.layoutIfNeeded()
        XCTAssertGreaterThan(text.contentSize.height, text.bounds.height)
        XCTAssertGreaterThan(text.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(text.contentSize.height - text.contentOffset.y - text.bounds.height, 4)
        text.setContentOffset(.zero, animated: false)
        refresh(k); k.view.layoutIfNeeded()
        XCTAssertEqual(text.contentOffset.y, 0, accuracy: 1)
        snapshot.partialText += "\nNewest words"
        try bridge.write(snapshot: snapshot); refresh(k); k.view.layoutIfNeeded()
        XCTAssertGreaterThan(text.contentOffset.y, 0)
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.topEdgeEffect.isHidden)
        XCTAssertTrue(text.bottomEdgeEffect.isHidden)
    }

    func testListeningUsesIconControlsAndCompactPolish() throws {
        var snapshot = SharedSessionSnapshot(phase: .listening, partialText: "Speaking now")
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        k.view.frame = CGRect(x: 0, y: 0, width: 393, height: 250)
        k.view.layoutIfNeeded()
        func visible(_ view: UIView) -> Bool {
            !view.isHidden && (view.superview.map { visible($0) } ?? true)
        }
        for title in ["space", "return", "⌫", "More", "123"] {
            XCTAssertFalse(visible(try button(title, k.view)), title)
        }
        XCTAssertTrue(visible(try button("Cancel dictation", k.view)))
        let stop = try button("Stop and insert", k.view)
        XCTAssertTrue(visible(stop))
        let cancel = try button("Cancel dictation", k.view)
        XCTAssertGreaterThan(stop.frame.midX, cancel.frame.midX)
        XCTAssertGreaterThan(stop.bounds.width, 90)
        XCTAssertNil(stop.configuration?.title)
        XCTAssertNil(cancel.configuration?.title)
        XCTAssertNotNil(stop.configuration?.image)
        let polish = try button("Polish", k.view)
        XCTAssertLessThan(polish.bounds.width, 140)
        XCTAssertEqual(stop.bounds.height, 56, accuracy: 1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: k.view.bounds).image { context in
            UIColor.systemBackground.setFill()
            context.fill(k.view.bounds)
            k.view.drawHierarchy(in: k.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Listening keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
        k.view.frame.size.width = 320; k.view.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(stop.frame.minX, polish.frame.maxX)
        XCTAssertGreaterThanOrEqual(polish.bounds.width, 80)
        snapshot.phase = .ready
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertTrue(visible(try button("space", k.view)))
        XCTAssertTrue(visible(try button("123", k.view)))
        XCTAssertFalse(visible(try button("Cancel dictation", k.view)))
    }

    func testIdleToolbarAndResultTransitionsKeepControlsReachable() throws {
        var snapshot = SharedSessionSnapshot(phase: .ready, keyboardSessionActive: true)
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        func visible(_ view: UIView) -> Bool { !view.isHidden && (view.superview.map(visible) ?? true) }
        for title in ["q", "Polish", "More", "Undo insertion", "Start dictation"] {
            XCTAssertTrue(visible(try button(title, k.view)), title)
        }
        k.view.frame = CGRect(x: 0, y: 0, width: 393, height: 274); k.view.layoutIfNeeded()
        let mic = try button("Start dictation", k.view)
        XCTAssertLessThan(mic.convert(mic.bounds, to: k.view).maxY,
                          try button("q", k.view).convert(try button("q", k.view).bounds, to: k.view).minY)
        let preview = XCTAttachment(image: UIGraphicsImageRenderer(bounds: k.view.bounds).image { context in
            k.view.drawHierarchy(in: k.view.bounds, afterScreenUpdates: true)
        })
        preview.name = "Default QWERTY toolbar"; preview.lifetime = .keepAlways; add(preview)
        snapshot.phase = .listening; snapshot.partialText = "hello"
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertFalse(visible(try button("q", k.view)))
        XCTAssertTrue(visible(try button("Stop and insert", k.view)))
        snapshot.phase = .finalizing
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertFalse(visible(try button("q", k.view)))
        snapshot.phase = .ready; snapshot.processedText = "Hello."; snapshot.shouldAutoInsert = true
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertEqual(k.document.text, "existing Hello.")
        XCTAssertTrue(visible(try button("q", k.view)))
        XCTAssertTrue(visible(try button("Undo insertion", k.view)))
        func identified(_ view: UIView, _ id: String) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            return view.subviews.compactMap { identified($0, id) }.first
        }
        XCTAssertTrue(visible(try XCTUnwrap(identified(k.view, "correctionRow"))))
        // A stale recorder must not make an unfinished draft disappear behind keys.
        snapshot = SharedSessionSnapshot(phase: .listening, partialText: "unfinished", updatedAt: .distantPast)
        try bridge.write(snapshot: snapshot); refresh(k)
        XCTAssertFalse(visible(try button("q", k.view)))
        XCTAssertTrue(visible(try XCTUnwrap(identified(k.view, "keyboardTranscript"))))
    }

    func testDismissalDoesNotChangeRecorderAndTypingInvalidatesUndo() throws {
        let snapshot = SharedSessionSnapshot(phase: .ready, processedText: "hello")
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        try button("Clear", k.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(try bridge.readReceipt(snapshot.sessionID)?.disposition, .dismissed)
        XCTAssertEqual(try bridge.readSnapshot()?.processedText, "hello")
        try button("a", k.view).sendActions(for: .touchUpInside)
        try button("space", k.view).sendActions(for: .touchUpInside)
        try button("return", k.view).sendActions(for: .touchUpInside)
        try button("⌫", k.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(k.document.text, "existinga ")
    }
    func testFailureClearsPendingAndPreservesMessage() throws {
        var snapshot = SharedSessionSnapshot(phase: .ready, keyboardSessionActive: true)
        try bridge.write(snapshot: snapshot)
        let k = keyboard()
        try button("Start dictation", k.view).sendActions(for: .touchUpInside)
        let command = try XCTUnwrap(bridge.readCommand())
        snapshot.phase = .failed; snapshot.message = "Car disconnected"
        snapshot.acknowledgment = .init(id: command.id, rejection: "Car disconnected")
        try bridge.write(snapshot: snapshot); refresh(k)
        func labels(_ v: UIView) -> [String] { (v as? UILabel).flatMap { $0.text }.map { [$0] } ?? v.subviews.flatMap(labels) }
        XCTAssertTrue(labels(k.view).contains("Car disconnected"))
    }
    func testOldISODateSnapshotsAndCorruptFilesAreHandled() throws {
        let snapshot = SharedSessionSnapshot(phase: .ready, processedText: "legacy")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: root.appendingPathComponent("voice-session.json"))
        XCTAssertEqual(try bridge.readSnapshot()?.processedText, "legacy")
        try Data("broken".utf8).write(to: root.appendingPathComponent("voice-session.json"))
        XCTAssertThrowsError(try bridge.readSnapshot())
        let k = keyboard(); XCTAssertNotNil(k.view)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("voice-session.json"), encoding: .utf8), "broken")
    }
}
