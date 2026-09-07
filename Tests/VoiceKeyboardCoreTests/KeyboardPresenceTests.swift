import XCTest
@testable import VoiceKeyboardCore

final class KeyboardPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000.25)
    private func presence(_ visible: Bool = true, lastVisible: Double, updated: Double) -> KeyboardPresence {
        KeyboardPresence(keyboardID: UUID(), isVisible: visible,
            lastVisibleAt: start.addingTimeInterval(lastVisible), updatedAt: start.addingTimeInterval(updated))
    }

    func testInitialAppSwitchAndOldPresenceDoNotStopRecording() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start)
        XCTAssertFalse(lifecycle.shouldStop(presence: nil, now: start.addingTimeInterval(3600)))
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(false, lastVisible: -2, updated: -1),
            now: start.addingTimeInterval(3600)))
    }

    func testDismissalStopsAfterGracePeriodEvenIfFirstReadIsHidden() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start)
        let hidden = presence(false, lastVisible: 0.1, updated: 0.2)
        XCTAssertFalse(lifecycle.shouldStop(presence: hidden, now: start.addingTimeInterval(3.19)))
        XCTAssertTrue(lifecycle.shouldStop(presence: hidden, now: start.addingTimeInterval(3.21)))
    }

    func testReturningWithinGracePeriodKeepsRecording() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start)
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(lastVisible: 1, updated: 1), now: start.addingTimeInterval(1)))
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(false, lastVisible: 1, updated: 2), now: start.addingTimeInterval(2)))
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(lastVisible: 4, updated: 4), now: start.addingTimeInterval(4)))
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(lastVisible: 5, updated: 5), now: start.addingTimeInterval(5)))
    }

    func testTerminatedExtensionOrMissingPresenceStopsRecording() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start)
        let visible = presence(lastVisible: 1, updated: 1)
        XCTAssertFalse(lifecycle.shouldStop(presence: visible, now: start.addingTimeInterval(1)))
        XCTAssertFalse(lifecycle.shouldStop(presence: nil, now: start.addingTimeInterval(3.9)))
        XCTAssertTrue(lifecycle.shouldStop(presence: visible, now: start.addingTimeInterval(4)))
        XCTAssertTrue(lifecycle.shouldStop(presence: nil, now: start.addingTimeInterval(4)))
    }

    func testVisibleKeyboardHasNoDurationLimit() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start)
        for tick in 1...7200 {
            let time = Double(tick)
            XCTAssertFalse(lifecycle.shouldStop(presence: presence(lastVisible: time, updated: time),
                now: start.addingTimeInterval(time)))
        }
    }

    func testOldEventsCannotOverrideNewPresence() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start)
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(lastVisible: 4, updated: 4), now: start.addingTimeInterval(4)))
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(false, lastVisible: 1, updated: 2), now: start.addingTimeInterval(5)))
        XCTAssertTrue(lifecycle.shouldStop(presence: nil, now: start.addingTimeInterval(7)))
    }

    func testNewRecordingDoesNotInheritPreviousKeyboardUse() {
        var lifecycle = KeyboardRecordingLifecycle(startedAt: start.addingTimeInterval(20))
        XCTAssertFalse(lifecycle.shouldStop(presence: presence(false, lastVisible: 1, updated: 2),
            now: start.addingTimeInterval(100)))
    }
}
