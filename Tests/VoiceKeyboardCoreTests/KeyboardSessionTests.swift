import Foundation
import XCTest
@testable import VoiceKeyboardCore

final class KeyboardSessionTests: XCTestCase {
    func testSessionRequiresUnexpiredLeaseAndLiveHeartbeat() {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = SharedSessionSnapshot(updatedAt: now, keyboardSessionExpiresAt: now.addingTimeInterval(1800))
        XCTAssertTrue(snapshot.isKeyboardSessionActive(at: now.addingTimeInterval(4)))
        XCTAssertFalse(snapshot.isKeyboardSessionActive(at: now.addingTimeInterval(6)))
        XCTAssertFalse(snapshot.isKeyboardSessionActive(at: now.addingTimeInterval(-10)))
        var expired = snapshot
        expired.keyboardSessionExpiresAt = now
        XCTAssertFalse(expired.isKeyboardSessionActive(at: now))
        XCTAssertFalse(SharedSessionSnapshot(updatedAt: now).isKeyboardSessionActive(at: now))
    }

    func testTwoMinuteIdleDeadlineAndFreshRecordingHeartbeat() throws {
        let stopped = Date(timeIntervalSince1970: 1000)
        let deadline = KeyboardReadiness.deadline(after: stopped)
        XCTAssertFalse(KeyboardReadiness.hasExpired(deadline: deadline, at: stopped.addingTimeInterval(119)))
        XCTAssertTrue(KeyboardReadiness.hasExpired(deadline: deadline, at: stopped.addingTimeInterval(120)))
        // Beginning a new recording removes the idle deadline; a fresh heartbeat
        // must keep the keyboard usable even after the previous deadline passed.
        let later = stopped.addingTimeInterval(600)
        let recording = SharedSessionSnapshot(phase: .listening, updatedAt: later, keyboardSessionActive: true)
        XCTAssertTrue(recording.isKeyboardSessionActive(at: later))
        XCTAssertFalse(recording.isKeyboardSessionActive(at: later.addingTimeInterval(6)))
        let decoded = try JSONDecoder().decode(SharedSessionSnapshot.self, from: JSONEncoder().encode(recording))
        XCTAssertTrue(decoded.isKeyboardSessionActive(at: later))
    }

    func testEndedSessionPreservesInsertableText() {
        let snapshot = SharedSessionSnapshot(phase: .ready, finalizedText: "Saved words", processedText: "Saved words.", keyboardSessionActive: false)
        XCTAssertFalse(snapshot.isKeyboardSessionActive())
        XCTAssertEqual(snapshot.insertableText, "Saved words.")
    }

    func testLegacyEngineHistoryStillDecodesButOnlyParakeetIsOffered() throws {
        XCTAssertEqual(SpeechEngineID.allCases, [.parakeetStreaming])
        XCTAssertEqual(try JSONDecoder().decode(SpeechEngineID.self, from: Data("\"maiTranscribe2\"".utf8)), .maiTranscribe2)
    }

    func testOldSnapshotDecodesWithoutSession() throws {
        let source = SharedSessionSnapshot()
        let data = try JSONEncoder().encode(source)
        // Optional fields are omitted by the encoder, as in pre-session installs.
        let decoded = try JSONDecoder().decode(SharedSessionSnapshot.self, from: data)
        XCTAssertNil(decoded.keyboardSessionExpiresAt)
        XCTAssertFalse(decoded.isKeyboardSessionActive())
    }

    func testKeyboardCommandsCarryTranscriptIdentity() throws {
        for kind in [VoiceCommandKind.start, .endSession, .clear, .stopAndInsert] {
            let command = VoiceCommand(kind: kind, sessionID: UUID())
            let decoded = try JSONDecoder().decode(VoiceCommand.self, from: JSONEncoder().encode(command))
            XCTAssertEqual(decoded, command)
        }
    }

    func testSessionControlsAreNotAccidentalSpokenCommands() {
        XCTAssertNil(SpokenVoiceCommandParser.match(in: "start"))
        XCTAssertNil(SpokenVoiceCommandParser.match(in: "end session"))
    }
}
