import XCTest
@testable import VoiceKeyboardCore

final class VoiceLiveTests: XCTestCase {
    func testClearCannotFinishStopBeforeCommitAcknowledgement() {
        var gate = VoiceLiveStopGate()
        gate.begin(commitID: "stop")
        gate.didClear()
        XCTAssertFalse(gate.canClear(transcriptionPending: false))
        XCTAssertFalse(gate.canFinish(transcriptionPending: false))
        gate.didCommit()
        XCTAssertFalse(gate.canFinish(transcriptionPending: true))
        XCTAssertTrue(gate.canFinish(transcriptionPending: false))
    }

    func testStopDrainsTranscriptBeforeClearingAndWaitsForClear() {
        var gate = VoiceLiveStopGate()
        gate.begin(commitID: "stop")
        gate.didCommit()
        XCTAssertFalse(gate.canClear(transcriptionPending: true))
        XCTAssertTrue(gate.canClear(transcriptionPending: false))
        XCTAssertFalse(gate.canFinish(transcriptionPending: false))
        gate.didClear()
        XCTAssertTrue(gate.canFinish(transcriptionPending: false))
    }

    func testOnlyMatchingEmptyCommitCanAcknowledgeStop() {
        var gate = VoiceLiveStopGate()
        gate.didCommit() // An earlier automatic commit is not our Stop.
        gate.begin(commitID: "stop")
        XCTAssertFalse(gate.didRejectEmptyCommit(eventID: "other"))
        XCTAssertFalse(gate.canClear(transcriptionPending: false))
        XCTAssertTrue(gate.didRejectEmptyCommit(eventID: "stop"))
        XCTAssertTrue(gate.canClear(transcriptionPending: false))
        gate.begin(commitID: "next")
        XCTAssertFalse(gate.canClear(transcriptionPending: false))
    }

    func testAzureMayOmitTheEmptyCommitRequestIDOnlyDuringStop() {
        var gate = VoiceLiveStopGate()
        XCTAssertFalse(gate.didRejectEmptyCommit(eventID: nil))
        gate.begin(commitID: "stop")
        XCTAssertTrue(gate.didRejectEmptyCommit(eventID: nil))
        XCTAssertTrue(gate.canClear(transcriptionPending: false))
        XCTAssertFalse(gate.canClear(transcriptionPending: true))
    }

    func testPauseProfilesRequireMatchingServiceConfirmation() throws {
        for profile in VoiceLiveProtocol.TurnDetection.allCases {
            let configuration = VoiceLiveProtocol.configuration(turnDetection: profile)
            XCTAssertTrue(VoiceLiveProtocol.confirmsConfiguration(configuration, turnDetection: profile))
            var session = try XCTUnwrap(configuration["session"] as? [String: Any])
            var vad = try XCTUnwrap(session["turn_detection"] as? [String: Any])
            vad["silence_duration_ms"] = 250
            session["turn_detection"] = vad
            XCTAssertFalse(VoiceLiveProtocol.confirmsConfiguration(["session": session], turnDetection: profile))
            vad["silence_duration_ms"] = profile.settings["silence_duration_ms"]
            vad["create_response"] = true
            session["turn_detection"] = vad
            XCTAssertFalse(VoiceLiveProtocol.confirmsConfiguration(["session": session], turnDetection: profile))
        }
        let session = try XCTUnwrap(VoiceLiveProtocol.configuration()["session"] as? [String: Any])
        let vad = try XCTUnwrap(session["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 1500)
    }

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
