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
    private let audioWorker = RecordingAudioWorker()
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
        guard !stopped else { throw CancellationError() }
        continuation.yield(.preparing(message: "Preparing Parakeet (731 MB download on first use)…", progress: nil))
        let url = try await ParakeetModelStore.shared.modelURL(allowDownload: allowModelDownload)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        continuation.yield(.preparing(message: "Loading Parakeet on this iPhone…", progress: nil))
        // CPU keeps inference available while the keyboard's host app is foreground.
        try await worker.prepare(modelURL: url)
        guard !stopped else { throw CancellationError() }
    }

    func start() async throws {
        guard !stopped else { throw CancellationError() }
        do {
            try await audioWorker.open(archiveURL)
            guard !stopped else { throw CancellationError() }
            let pair = AsyncStream.makeStream(of: OwnedAudioBuffer.self, bufferingPolicy: .bufferingOldest(64))
            input = pair.continuation
            audioEngine.setConsumer(AudioCaptureTap.make(copy: { OwnedAudioBuffer($0) }, audio: pair.continuation,
                    events: continuation, overflowMessage: "Parakeet could not keep up with microphone audio. End the session and try a shorter dictation."))
            tapped = true
            captureTask = Task { [weak self] in
                for await owned in pair.stream {
                    guard !Task.isCancelled, let self else { return }
                    do {
                        let samples = try await self.audioWorker.samples(owned)
                        if let text = try await self.worker.feed(samples) {
                            // Replace the whole hypothesis, preserving native punctuation and casing.
                            self.continuation.yield(.partial(text: text, receivedAt: Date()))
                        }
                    } catch {
                        DiagnosticLog.error("audio.process-buffer", error)
                        self.continuation.yield(.failure(message: error.localizedDescription))
                        return
                    }
                }
            }
        } catch {
            await stopCapture()
            await worker.cancel()
            throw error
        }
    }

    private func stopCapture() async {
        if tapped { audioEngine.removeConsumer(); tapped = false }
        audioEngine.stop(); input?.finish(); input = nil
        await captureTask?.value; captureTask = nil
        await audioWorker.close()
    }

    func stop() async throws {
        guard !stopped else { return }
        stopped = true
        await stopCapture()
        defer {
            continuation.finish()
        }
        let start = Date()
        let text = try await worker.finish()
        continuation.yield(.final(text: text, endOfUtteranceLatencyMilliseconds: Date().timeIntervalSince(start) * 1000, receivedAt: Date()))
    }

    func cancel() async {
        stopped = true
        captureTask?.cancel()
        await stopCapture()
        await worker.cancel()
        continuation.finish()
    }
}

/// Owns conversion and archive I/O away from the UI actor.
actor RecordingAudioWorker {
    private var archive: AudioArchive?
    private let converter = AudioBufferConverter()
    func open(_ url: URL?) throws { if let url { archive = try AudioArchive(url: url) } }
    func append(_ owned: OwnedAudioBuffer) throws { try archive?.append(owned.buffer) }
    func samples(_ owned: OwnedAudioBuffer) throws -> [Float] {
        try append(owned)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = try converter.convert(owned.buffer, to: format)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    func close() { archive?.close(); archive = nil }
}
