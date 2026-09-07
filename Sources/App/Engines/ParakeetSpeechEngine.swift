@preconcurrency import AVFoundation
import Foundation
import VoiceKeyboardCore

@MainActor
final class ParakeetSpeechEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .parakeetStreaming
    let updates: AsyncStream<SpeechEngineUpdate>
    var archiveURL: URL?
    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private let worker = ParakeetWorker()
    private let audioEngine = MicrophoneCapture.shared
    private let converter = AudioBufferConverter()
    private var archive: AudioArchive?
    private var input: AsyncStream<OwnedAudioBuffer>.Continuation?
    private var captureTask: Task<Void, Never>?
    private var tapped = false
    private var stopped = false
    private let allowModelDownload: Bool

    init(allowModelDownload: Bool = true) {
        self.allowModelDownload = allowModelDownload
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        updates = pair.stream; continuation = pair.continuation
    }

    func prepare() async throws {
        continuation.yield(.preparing(message: "Preparing Parakeet (731 MB download on first use)…", progress: nil))
        let url = try await ParakeetModelStore.shared.modelURL(allowDownload: allowModelDownload)
        try Task.checkCancellation()
        continuation.yield(.preparing(message: "Loading Parakeet on this iPhone…", progress: nil))
        // CPU keeps inference available while the keyboard's host app is foreground.
        try await worker.prepare(modelURL: url)
    }

    func start() async throws {
        try audioEngine.configure()
        do {
            if let archiveURL { archive = try AudioArchive(url: archiveURL) }
            let pair = AsyncStream.makeStream(of: OwnedAudioBuffer.self, bufferingPolicy: .bufferingOldest(64))
            input = pair.continuation
            audioEngine.setConsumer(AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) }, audio: pair.continuation,
                    events: continuation, overflowMessage: "Parakeet could not keep up with microphone audio. End the session and try a shorter dictation."))
            tapped = true
            captureTask = Task { [weak self] in
                for await owned in pair.stream {
                    guard let self else { return }
                    do {
                        try self.archive?.append(owned.buffer)
                        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                        let buffer = try self.converter.convert(owned.buffer, to: format)
                        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                        if let text = try await self.worker.feed(samples) {
                            // Replace the whole hypothesis, preserving native punctuation and casing.
                            self.continuation.yield(.partial(text: text, receivedAt: Date()))
                        }
                    } catch {
                        self.continuation.yield(.failure(message: error.localizedDescription))
                        return
                    }
                }
            }
            try audioEngine.start()
        } catch {
            await stopCapture()
            await worker.cancel()
            audioEngine.deactivateIfUnused()
            throw error
        }
    }

    private func stopCapture() async {
        if tapped { audioEngine.removeConsumer(); tapped = false }
        audioEngine.stop(); input?.finish(); input = nil
        await captureTask?.value; captureTask = nil
        archive?.close(); archive = nil
    }

    func stop() async throws {
        guard !stopped else { return }
        stopped = true
        await stopCapture()
        defer {
            continuation.finish()
            audioEngine.deactivateIfUnused()
        }
        let start = Date()
        let text = try await worker.finish()
        continuation.yield(.final(text: text, endOfUtteranceLatencyMilliseconds: Date().timeIntervalSince(start) * 1000, receivedAt: Date()))
    }

    func discardCurrentAudio() async throws {
        await stopCapture()
        await worker.cancel()
        try await prepare()
        try await start()
    }
}
