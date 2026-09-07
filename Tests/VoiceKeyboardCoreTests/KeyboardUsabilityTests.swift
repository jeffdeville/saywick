import XCTest
@testable import VoiceKeyboardCore

final class KeyboardUsabilityTests: XCTestCase {
    func testReadinessExpiresWithoutRevisionChange() {
        let now = Date()
        let snapshot = SharedSessionSnapshot(phase: .ready, updatedAt: now, keyboardSessionExpiresAt: now.addingTimeInterval(2), keyboardSessionActive: true)
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now), .ready)
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true, now: now.addingTimeInterval(3)), .activationNeeded)
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: false, now: now), .needsAccess)
    }
    func testStaleRecordingCannotOfferStop() {
        let snapshot = SharedSessionSnapshot(phase: .listening, updatedAt: Date().addingTimeInterval(-10))
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true), .activationNeeded)
    }
    func testRecordingAndMeetingHaveDifferentActions() {
        var snapshot = SharedSessionSnapshot(phase: .listening)
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true).command, .stopAndInsert)
        snapshot.isMeeting = true
        XCTAssertEqual(KeyboardRecordingState.resolve(snapshot, fullAccess: true).command, .stop)
        snapshot.phase = .finalizing
        XCTAssertNil(KeyboardRecordingState.resolve(snapshot, fullAccess: true).command)
    }
    func testStandaloneWordsCorrectCloseSpellingsAndSpacing() throws {
        let words = try CustomVocabulary("Breccan\nSaywick")
        XCTAssertEqual(words.apply(to: "Tell Brecken about say wick."), "Tell Breccan about Saywick.")
        XCTAssertEqual(words.apply(to: "The other person is here."), "The other person is here.")
    }
    func testAmbiguousNamesAndCommonWordsStayUnchanged() throws {
        let words = try CustomVocabulary("Breccan\nBreckan\nMay\nWill")
        XCTAssertEqual(words.apply(to: "Brecken may come and will call."), "Brecken may come and will call.")
    }
    func testExplicitRulesKeepPriorityAndDoNotCascade() throws {
        let words = try CustomVocabulary("Brecken = Sam\nBreccan\nSam = Samuel")
        XCTAssertEqual(words.apply(to: "Brecken called Sam."), "Sam called Samuel.")
    }
}
