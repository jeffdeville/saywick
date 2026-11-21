import XCTest
import VoiceKeyboardCore
import AVFoundation
@testable import LocalVoiceKeyboard

@MainActor
final class AudioArchiveTests: XCTestCase {
    func testNormalizeStereoBufferAndResetArchive() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("normalized.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for channel in 0..<2 {
            for index in 0..<48000 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.04) * 0.1) }
        }
        let writer = try AudioArchive(url: target)
        try writer.append(buffer)
        writer.close()
        let normalized = try AVAudioFile(forReading: target)
        XCTAssertEqual(normalized.processingFormat.sampleRate, 16000)
        XCTAssertEqual(normalized.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(normalized.length) / 16000, 1, accuracy: 0.01)

        let resetURL = folder.appendingPathComponent("reset.wav")
        let archive = try AudioArchive(url: resetURL)
        try archive.append(buffer)
        try archive.reset()
        try archive.append(buffer)
        archive.close()
        XCTAssertEqual(Double(try AVAudioFile(forReading: resetURL).length) / 16000, 1, accuracy: 0.01)
    }

    func testPreviouslyImportedRecordingRemainsAccessibleInHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TranscriptHistoryStore(root: root)
        let entry = TranscriptHistoryEntry(title: "Earlier recording", source: "Imported audio", hasAudio: true)
        try store.save(entry)
        let url = store.audioURL(entry.id)
        let archive = try AudioArchive(url: url)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        samples.frameLength = 1600
        try archive.append(samples)
        archive.close()

        let history = HistoryModel()
        history.store = store
        history.reload()
        let saved = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertEqual(saved.source, "Imported audio")
        let retainedURL = try XCTUnwrap(history.audioURL(saved))
        XCTAssertEqual(try AVAudioFile(forReading: retainedURL).length, 1600)
    }
}
