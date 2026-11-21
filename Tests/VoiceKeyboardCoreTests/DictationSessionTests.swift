import XCTest
@testable import VoiceKeyboardCore

final class DictationSessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    func activated() -> DictationSession {
        var s = DictationSession()
        XCTAssertEqual(s.send(.activate), .activate)
        XCTAssertEqual(s.send(.activated(s.generation, now)), .none)
        return s
    }
    func recording() -> DictationSession {
        var s = activated()
        XCTAssertEqual(s.send(.start), .start)
        XCTAssertEqual(s.send(.started(s.generation)), .none)
        return s
    }
    func testStartFinishAndIdleExpiryContract() {
        var s = recording()
        XCTAssertTrue(s.isBusy); XCTAssertNil(s.idleDeadline)
        XCTAssertEqual(s.send(.expire(now.addingTimeInterval(1000))), .none)
        XCTAssertEqual(s.state, .transcribing)
        XCTAssertEqual(s.send(.finish), .finish)
        XCTAssertEqual(s.send(.finish), .rejected)
        XCTAssertEqual(s.send(.completed(s.generation, retain: true, at: now)), .none)
        XCTAssertEqual(s.state, .activated)
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.send(.expire(now.addingTimeInterval(119))), .none)
        XCTAssertEqual(s.send(.expire(now.addingTimeInterval(120))), .release)
        XCTAssertTrue(s.isBusy)
        s.send(.settled(s.generation, retain: false, at: now))
        XCTAssertEqual(s.state, .inactive)
        XCTAssertFalse(s.ownsMicrophone)
    }
    func testCancelInvalidatesOldCompletionAndWaitsForCleanup() {
        var s = recording(); let old = s.generation
        XCTAssertEqual(s.send(.cancel), .cancel)
        XCTAssertNotEqual(s.generation, old)
        XCTAssertEqual(s.send(.start), .rejected)
        XCTAssertEqual(s.send(.completed(old, retain: true, at: now)), .rejected)
        XCTAssertEqual(s.send(.settled(old, retain: true, at: now)), .rejected)
        XCTAssertEqual(s.send(.settled(s.generation, retain: true, at: now)), .none)
        XCTAssertEqual(s.state, .activated)
        XCTAssertEqual(s.idleDeadline, now.addingTimeInterval(120))
    }
    func testFailureDuringEveryOperationCannotResurrectRecording() {
        var starting = activated(); starting.send(.start)
        var preparing = DictationSession(); preparing.send(.activate)
        var finalizing = recording(); finalizing.send(.finish)
        var cancelling = recording(); cancelling.send(.cancel)
        for original in [preparing, starting, recording(), finalizing, cancelling, activated()] {
            var s = original; let old = s.generation
            XCTAssertEqual(s.send(.failure("Disconnected")), .alert)
            XCTAssertEqual(s.state, .inactive); XCTAssertEqual(s.issue, "Disconnected")
            XCTAssertEqual(s.send(.started(old)), .rejected)
            XCTAssertEqual(s.send(.activated(old, now)), .rejected)
            XCTAssertEqual(s.send(.completed(old, retain: true, at: now)), .rejected)
            s.send(.settled(s.generation, retain: false, at: now))
            XCTAssertEqual(s.send(.failure("Duplicate")), .rejected)
            XCTAssertEqual(s.send(.clearIssue), .none); XCTAssertNil(s.issue)
        }
    }
    func testInvalidActionsAndNoRetention() throws {
        var s = DictationSession()
        for event: DictationSession.Event in [.start, .finish, .cancel, .deactivate,
            .started(UUID()), .activated(UUID(), now), .settled(UUID(), retain: true, at: now)] {
            XCTAssertEqual(s.send(event), .rejected)
        }
        s = recording(); XCTAssertEqual(s.send(.activate), .rejected)
        s.send(.finish)
        XCTAssertEqual(s.send(.completed(s.generation, retain: false, at: now)), .release)
        XCTAssertEqual(s.state, .inactive)
        XCTAssertEqual(try JSONDecoder().decode(DictationSession.self, from: JSONEncoder().encode(s)), s)
    }
    func testCanonicalSnapshotAndLegacyCompatibility() throws {
        var snapshot = SharedSessionSnapshot(updatedAt: now, keyboardSessionActive: true)
        var s = activated(); snapshot.dictation = s
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .ready)
        s.send(.start); snapshot.dictation = s
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .starting)
        s.send(.started(s.generation)); snapshot.dictation = s
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .recording)
        snapshot.isMeeting = true
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .meeting)
        s.send(.finish); snapshot.dictation = s
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .finishing)
        s.send(.failure("Error")); snapshot.dictation = s
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .finishing)
        s.send(.settled(s.generation, retain: false, at: now)); snapshot.dictation = s
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .activationNeeded)
        let command = VoiceCommand(kind: .cancel)
        snapshot.acknowledgment = .init(id: command.id, rejection: "Busy")
        XCTAssertEqual(try JSONDecoder().decode(SharedSessionSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let pending = PendingKeyboardCommand(command: command, sentAt: now)
        XCTAssertFalse(pending.timedOut(at: now.addingTimeInterval(4)))
        XCTAssertTrue(pending.timedOut(at: now.addingTimeInterval(5)))
        let receipt = ResultReceipt(resultID: snapshot.sessionID, disposition: .inserted)
        XCTAssertEqual(try JSONDecoder().decode(ResultReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
    }
}
