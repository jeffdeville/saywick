import Foundation
import XCTest
@testable import VoiceKeyboardCore

final class TranscriptAccumulatorTests: XCTestCase {
    func testPartialResultReplacesThePreviousPartial() {
        let start = Date(timeIntervalSince1970: 100)
        var accumulator = TranscriptAccumulator(startedAt: start)

        accumulator.consume(.partial(text: "hello", receivedAt: start.addingTimeInterval(0.2)))
        accumulator.consume(.partial(text: "hello there", receivedAt: start.addingTimeInterval(0.4)))

        XCTAssertEqual(accumulator.currentText, "hello there")
        XCTAssertEqual(accumulator.metrics.firstPartialMilliseconds ?? -1, 200, accuracy: 0.001)
    }

    func testFinalResultCommitsTheSegmentAndClearsThePartial() {
        let start = Date(timeIntervalSince1970: 100)
        var accumulator = TranscriptAccumulator(startedAt: start)

        accumulator.consume(.partial(text: " first draft ", receivedAt: start.addingTimeInterval(0.1)))
        accumulator.consume(.final(text: " first sentence ", endOfUtteranceLatencyMilliseconds: 280, receivedAt: start.addingTimeInterval(0.8)))
        accumulator.consume(.final(text: "second   sentence", endOfUtteranceLatencyMilliseconds: 240, receivedAt: start.addingTimeInterval(1.4)))

        XCTAssertEqual(accumulator.finalizedText, "first sentence second sentence")
        XCTAssertTrue(accumulator.partialText.isEmpty)
        XCTAssertEqual(accumulator.metrics.firstFinalMilliseconds ?? -1, 800, accuracy: 0.001)
        XCTAssertEqual(accumulator.metrics.latestEndOfUtteranceMilliseconds, 240)
        XCTAssertEqual(accumulator.metrics.finalizedCharacterCount, 30)
    }

    func testRuleBasedCleanupIsPredictableAndOffline() {
        XCTAssertEqual(RuleBasedCleaner.clean("  hello   from the phone  "), "Hello from the phone.")
        XCTAssertEqual(RuleBasedCleaner.clean("already done!"), "Already done!")
        XCTAssertTrue(RuleBasedCleaner.clean("   ").isEmpty)
    }

    func testReadySnapshotPrefersProcessedText() {
        let state = SharedSessionSnapshot(
            phase: .ready,
            finalizedText: "raw words",
            processedText: "Clean words."
        )

        XCTAssertEqual(state.insertableText, "Clean words.")
    }

    func testTranscriptOutputSanitizerRemovesModelPresentationWrappers() {
        XCTAssertEqual(
            TranscriptOutputSanitizer.clean("<transcript>\nClean words.\n</transcript>"),
            "Clean words."
        )
        XCTAssertEqual(
            TranscriptOutputSanitizer.clean("```transcript\nTranscript:\nClean words.\n```"),
            "Clean words."
        )
        XCTAssertEqual(
            TranscriptOutputSanitizer.clean("A literal <transcript> tag in the middle."),
            "A literal <transcript> tag in the middle."
        )
    }

    func testSpokenStopAndInsertCommandKeepsTextBeforeCommand() {
        XCTAssertEqual(
            SpokenVoiceCommandParser.match(in: "This is the useful text, stop and insert."),
            SpokenVoiceCommandMatch(
                command: .stopAndInsert,
                transcriptBeforeCommand: "This is the useful text"
            )
        )
    }

    func testSpokenRestartAndClearCommands() {
        XCTAssertEqual(
            SpokenVoiceCommandParser.match(in: "stop and restart"),
            SpokenVoiceCommandMatch(command: .restart, transcriptBeforeCommand: "")
        )
        XCTAssertEqual(
            SpokenVoiceCommandParser.match(in: "Clear transcript!"),
            SpokenVoiceCommandMatch(command: .clear, transcriptBeforeCommand: "")
        )
        XCTAssertNil(SpokenVoiceCommandParser.match(in: "The instructions are clear."))
    }
}
