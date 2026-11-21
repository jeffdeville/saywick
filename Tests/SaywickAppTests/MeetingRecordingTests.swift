import AVFoundation
import AppIntents
import XCTest
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor
final class MeetingRecordingTests: XCTestCase {
    func testMeetingsRetainAudioWhenDictationRetentionIsOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryModel()
        history.store = try TranscriptHistoryStore(root: root)
        let previous = history.keepAudio
        defer { history.keepAudio = previous }
        history.keepAudio = false
        let id = UUID()
        let url = try XCTUnwrap(history.begin(id: id, meeting: true))
        let engine = MeetingRecordingEngine()
        engine.archiveURL = url
        try await engine.prepare() // Opens audio storage; no microphone or model needed.
        try await engine.stop()
        try history.completeMeeting(id: id)
        let entry = try XCTUnwrap(history.entries.first { $0.id == id })
        XCTAssertEqual(entry.source, "Meeting recording")
        XCTAssertTrue(entry.hasAudio)
        XCTAssertTrue(entry.runs.isEmpty)
        XCTAssertEqual(entry.status, "Audio saved — transcribe with Parakeet")
    }

    func testRecordingShortcutsUseBackgroundSystemIntentProtocols() {
        func check<T: AudioRecordingIntent & LiveActivityIntent>(_ type: T.Type) {
            XCTAssertTrue(T.supportedModes.contains(.background))
        }
        check(StartSaywickDictation.self)
        check(StartSaywickMeeting.self)
        check(StopSaywickRecording.self)
    }
}
