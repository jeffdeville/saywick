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

    func testImportsRecordingLongerThanPreviousTwentyFiveMinuteLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("meeting.wav")
        let destination = root.appendingPathComponent("normalized.wav")
        // Low-rate silent PCM keeps this duration regression fixture compact.
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        memset(buffer.floatChannelData![0], 0, 8000 * MemoryLayout<Float>.size)
        for _ in 0..<1800 { try file?.write(from: buffer) }
        file = nil
        try await AudioFileTranscriber.normalizedCopy(from: source, to: destination)
        let imported = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Double(imported.length) / imported.processingFormat.sampleRate, 1800, accuracy: 1)
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
