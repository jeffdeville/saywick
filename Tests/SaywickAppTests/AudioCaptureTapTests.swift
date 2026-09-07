import XCTest
import AVFoundation
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor
final class AudioCaptureTapTests: XCTestCase {
    func testTapCreatedOnMainActorRunsOnAudioThreadAndOwnsItsSamples() async throws {
        let audio = AsyncStream.makeStream(of: OwnedAudioBuffer.self)
        let events = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        let tap = AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) },
            audio: audio.continuation, events: events.continuation, overflowMessage: "Overflow")
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            source.frameLength = 1
            source.floatChannelData![0][0] = 0.5
            tap(source, AVAudioTime(sampleTime: 0, atRate: 16000))
            source.floatChannelData![0][0] = 0
            audio.continuation.finish()
        }.value
        var iterator = audio.stream.makeAsyncIterator()
        let captured = await iterator.next()
        XCTAssertEqual(try XCTUnwrap(captured).buffer.floatChannelData![0][0], 0.5)
    }

    /// Run explicitly on a connected phone with microphone access already granted.
    func testParakeetMicrophoneOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an iPhone microphone and the Parakeet model")
        #else
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant Saywick microphone access before this device test")
        }
        let engine = ParakeetSpeechEngine()
        try await engine.prepare()
        try await engine.start()
        try await Task.sleep(for: .seconds(3))
        try await engine.stop()
        for await event in engine.updates {
            if case .failure(let message) = event { XCTFail(message) }
        }
        #endif
    }

    func testOverflowReportsFailureFromAudioThread() async {
        let audio = AsyncStream.makeStream(of: OwnedAudioBuffer.self, bufferingPolicy: .bufferingOldest(1))
        let events = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        let tap = AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) },
            audio: audio.continuation, events: events.continuation, overflowMessage: "Overflow")
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            source.frameLength = 1
            let time = AVAudioTime(sampleTime: 0, atRate: 16000)
            tap(source, time)
            tap(source, time)
            events.continuation.finish()
            audio.continuation.finish()
        }.value
        var iterator = events.stream.makeAsyncIterator()
        guard case .failure(let message) = await iterator.next() else {
            XCTFail("Expected an explicit overflow failure")
            return
        }
        XCTAssertEqual(message, "Overflow")
    }
}
