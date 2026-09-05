import XCTest
import AVFoundation
@testable import LocalVoiceKeyboard

@MainActor
final class AudioArchiveTests: XCTestCase {
    func testNormalizeStereoFileAndResetArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        let target = folder.appendingPathComponent("normalized.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for channel in 0..<2 {
            for index in 0..<48000 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.04) * 0.1) }
        }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        try await AudioFileTranscriber.normalizedCopy(from: source, to: target)
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

    func testInvalidImportIsRejectedBeforeWritingDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("invalid.wav")
        let target = folder.appendingPathComponent("destination.wav")
        try Data("not audio".utf8).write(to: source)
        do {
            try await AudioFileTranscriber.normalizedCopy(from: source, to: target)
            XCTFail("Invalid audio should not import")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
    }
}
