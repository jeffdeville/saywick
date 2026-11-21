import AppIntents
import XCTest
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor
final class MeetingRecordingTests: XCTestCase {
    func testRecordingShortcutsUseBackgroundSystemIntentProtocols() {
        func check<T: AudioRecordingIntent & LiveActivityIntent>(_ type: T.Type) {
            XCTAssertTrue(T.supportedModes.contains(.background))
        }
        check(StartSaywickDictation.self)
        check(StopSaywickRecording.self)
    }
}
