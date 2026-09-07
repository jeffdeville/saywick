@preconcurrency import AVFoundation
import Foundation
import VoiceKeyboardCore

/// Meeting capture deliberately avoids inference: audio is streamed to disk and
/// Parakeet can transcribe the saved recording later without recording-time load.
@MainActor
final class MeetingRecordingEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .parakeetStreaming
    let updates: AsyncStream<SpeechEngineUpdate>
    var archiveURL: URL?
    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private var archive: AudioArchive?
    private var input: AsyncStream<OwnedAudioBuffer>.Continuation?
    private var captureTask: Task<Void, Never>?
    private var started = false

    init() {
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        updates = pair.stream
        continuation = pair.continuation
    }
    func prepare() async throws {
        guard let archiveURL else { throw SpeechEngineError.unavailable("Meeting audio storage is unavailable.") }
        archive = try AudioArchive(url: archiveURL)
    }
    func start() async throws {
        let pair = AsyncStream.makeStream(of: OwnedAudioBuffer.self, bufferingPolicy: .bufferingOldest(64))
        input = pair.continuation
        MicrophoneCapture.shared.setConsumer(AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) },
            audio: pair.continuation, events: continuation, overflowMessage: "Meeting audio could not be saved fast enough. Check available storage."))
        captureTask = Task { [weak self] in
            for await owned in pair.stream {
                guard let self else { return }
                do { try archive?.append(owned.buffer) }
                catch { continuation.yield(.failure(message: error.localizedDescription)); return }
            }
        }
        started = true
        do { try MicrophoneCapture.shared.start() }
        catch { try? await stop(); throw error }
    }
    func stop() async throws {
        if started {
            MicrophoneCapture.shared.removeConsumer()
            MicrophoneCapture.shared.stop()
            started = false
        }
        input?.finish(); input = nil
        await captureTask?.value; captureTask = nil
        archive?.close(); archive = nil
        continuation.finish()
    }
}
