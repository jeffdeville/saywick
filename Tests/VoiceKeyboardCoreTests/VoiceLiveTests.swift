import XCTest
@testable import VoiceKeyboardCore

final class VoiceLiveTests: XCTestCase {
    func testFinalReplacesDeltasAndDuplicateCompletionIsIgnored() {
        var state = VoiceLiveTranscript()
        state.commit("a")
        state.delta("Hello", id: "a")
        state.delta(" there", id: "a")
        XCTAssertEqual(state.partialText, "Hello there")
        state.complete("Hello there.", id: "a")
        XCTAssertEqual(state.drain(), ["Hello there."])
        state.complete("Hello there.", id: "a")
        state.delta(" there", id: "a")
        XCTAssertEqual(state.drain(), [])
        XCTAssertEqual(state.partialText, "")
        XCTAssertFalse(state.isPending)
    }

    func testCompletionOrderCannotReorderDictation() {
        var state = VoiceLiveTranscript()
        state.commit("a")
        state.commit("b")
        state.complete("Second.", id: "b")
        XCTAssertEqual(state.drain(), [])
        XCTAssertTrue(state.isPending)
        state.complete("First.", id: "a")
        XCTAssertEqual(state.drain(), ["First.", "Second."])
    }

    func testClearDiscardsLateOldEventsButPreservesNewSpeech() {
        var state = VoiceLiveTranscript()
        state.commit("a")
        state.beginClear()
        state.commit("b")
        state.finishClear()
        state.complete("Old.", id: "a")
        state.complete("Old pending.", id: "b")
        state.commit("c")
        state.complete("Very very good.", id: "c")
        XCTAssertEqual(state.drain(), ["Very very good."])
    }

    func testLiveConfigurationDisablesRepliesAndUsesDocumentedAlias() throws {
        let event = VoiceLiveProtocol.configuration()
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let vad = try XCTUnwrap(session["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["create_response"] as? Bool, false)
        XCTAssertEqual((session["input_audio_transcription"] as? [String: String])?["model"], "mai-transcribe")
        let url = try VoiceLiveProtocol.endpoint("https://test.cognitiveservices.azure.com/")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/voice-live/realtime")
        XCTAssertFalse(url.absoluteString.contains("api-key"))
    }
}
