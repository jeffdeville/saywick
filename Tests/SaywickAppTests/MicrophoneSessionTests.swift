import XCTest
import AVFoundation
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor
final class MicrophoneSessionTests: XCTestCase {
    func testIdleAudioIsDiscardedAndNextDictationGetsOnlyNewSamples() async throws {
        let delivery = MicrophoneDelivery()
        let first = AsyncStream.makeStream(of: OwnedAudioBuffer.self)
        let second = AsyncStream.makeStream(of: OwnedAudioBuffer.self)
        let events = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            buffer.frameLength = 1
            let time = AVAudioTime(sampleTime: 0, atRate: 16000)
            delivery.setConsumer(AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) },
                audio: first.continuation, events: events.continuation, overflowMessage: "overflow"))
            buffer.floatChannelData![0][0] = 0.25
            delivery.receive(buffer, at: time)
            delivery.setConsumer(nil)
            buffer.floatChannelData![0][0] = 0.5
            delivery.receive(buffer, at: time) // Must reach neither transcript.
            delivery.setConsumer(AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) },
                audio: second.continuation, events: events.continuation, overflowMessage: "overflow"))
            buffer.floatChannelData![0][0] = 0.75
            delivery.receive(buffer, at: time)
            delivery.setConsumer(nil)
            first.continuation.finish()
            second.continuation.finish()
        }.value
        var firstSamples: [Float] = []
        var secondSamples: [Float] = []
        for await sample in first.stream { firstSamples.append(sample.buffer.floatChannelData![0][0]) }
        for await sample in second.stream { secondSamples.append(sample.buffer.floatChannelData![0][0]) }
        XCTAssertEqual(firstSamples, [0.25])
        XCTAssertEqual(secondSamples, [0.75])
    }

    func testMicrophoneSurvivesDictationStopOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical microphone capture")
        #else
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant Saywick microphone access before running")
        }
        let capture = MicrophoneCapture.shared
        defer { capture.endSession() }
        try capture.beginSession()
        capture.stop()
        XCTAssertTrue(capture.isRunning)
        try await Task.sleep(for: .seconds(1))
        try capture.start()
        XCTAssertTrue(capture.isRunning)
        capture.endSession()
        XCTAssertFalse(capture.isRunning)
        #endif
    }
}
