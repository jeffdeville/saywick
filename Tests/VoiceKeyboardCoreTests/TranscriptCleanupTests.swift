import XCTest
@testable import VoiceKeyboardCore

final class TranscriptCleanupTests: XCTestCase {
    func testThinkingPauseCanBeRepairedWithoutChangingWords() {
        XCTAssertTrue(TranscriptCleanup.preservesWords(
            source: "I think we should. Move the meeting to Friday.",
            candidate: "I think we should move the meeting to Friday."))
        XCTAssertTrue(TranscriptCleanup.preservesWords(
            source: "Could you. Ask Breccan about the API?",
            candidate: "Could you ask Breccan about the API?"))
    }

    func testRejectsRewritingOmissionsReorderingAndContextLeakage() {
        let source = "I do not want to move the meeting."
        for candidate in ["I want to move the meeting.", "I do not wish to move the meeting.",
                          "I do not want the meeting to move.", source + " Thank you.", ""] {
            XCTAssertFalse(TranscriptCleanup.preservesWords(source: source, candidate: candidate))
        }
    }

    func testProtectsNumbersContractionsAcronymsAndSymbols() {
        for (source, candidate) in [("Pay $5.25", "Pay $525"), ("Use -5 degrees", "Use 5 degrees"), ("Use the API", "Use the api"),
                                    ("I can't go", "I cant go"), ("Pay $5", "Pay 5"),
                                    ("Increase by 5%", "Increase by 5")] {
            XCTAssertFalse(TranscriptCleanup.preservesWords(source: source, candidate: candidate))
        }
        XCTAssertTrue(TranscriptCleanup.preservesWords(source: "I can’t go", candidate: "I can't go."))
    }

    func testLongTranscriptTargetsCoverEveryWordOnceWithReadOnlyContext() {
        let words = (0..<3000).map { "word\($0)" }
        let chunks = TranscriptCleanup.chunks(words.joined(separator: " "))
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(separator: " "), words.joined(separator: " "))
        XCTAssertTrue(chunks.first!.before.isEmpty)
        XCTAssertTrue(chunks.last!.after.isEmpty)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.text.utf8.count, TranscriptCleanup.targetByteLimit)
            XCTAssertLessThanOrEqual(chunk.before.utf8.count, TranscriptCleanup.contextByteLimit)
            XCTAssertLessThanOrEqual(chunk.after.utf8.count, TranscriptCleanup.contextByteLimit)
            if index > 0 { XCTAssertTrue(chunks[index - 1].text.hasSuffix(chunk.before)) }
            if index + 1 < chunks.count { XCTAssertTrue(chunks[index + 1].text.hasPrefix(chunk.after)) }
        }
    }

    func testLongProsePrefersCompleteProcessingSectionsWithoutLosingWords() {
        let text = (0..<90).map { "Record \($0) is ready." }.joined(separator: " ")
        let chunks = TranscriptCleanup.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasSuffix("ready.") })
        XCTAssertTrue(chunks.allSatisfy { $0.text.utf8.count <= TranscriptCleanup.targetByteLimit })
        XCTAssertEqual(chunks.map(\.text).joined(separator: " "), text)
    }

    func testUnicodeAndWhitespaceSurviveChunking() {
        let text = String(repeating: "café 日本語 👋🏽\n", count: 200)
        let chunks = TranscriptCleanup.chunks(text)
        XCTAssertEqual(chunks.map(\.text).joined(separator: " "), text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        XCTAssertTrue(chunks.allSatisfy { $0.text.utf8.count <= TranscriptCleanup.targetByteLimit })
        XCTAssertEqual(TranscriptCleanup.chunks(" \n"), [])
    }

    func testOversizedSingleWordIsPreservedForCallerToRejectNotTruncated() {
        let text = String(repeating: "x", count: 5000)
        XCTAssertEqual(TranscriptCleanup.chunks(text).map(\.text), [text])
    }

    func testBulletFormattingIsExplicit() {
        XCTAssertTrue(TranscriptCleanup.hasListMarkup("- First item\n- Second item"))
        XCTAssertTrue(TranscriptCleanup.hasListMarkup("1. First item"))
        XCTAssertFalse(TranscriptCleanup.hasListMarkup("The temperature is -5 degrees."))
        XCTAssertTrue(TranscriptCleanup.preservesWords(source: "First item Second item", candidate: "- First item\n- Second item"))
    }

    func testExistingProcessorIdentifiersRemainDecodable() throws {
        XCTAssertEqual(try JSONDecoder().decode(PostProcessorID.self, from: Data(#""foundationModels""#.utf8)), .foundationModels)
        XCTAssertTrue(PostProcessorID.foundationModelsStructured.usesLanguageModel)
        XCTAssertFalse(PostProcessorID.none.usesLanguageModel)
    }
}
