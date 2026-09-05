@preconcurrency import AVFoundation
import Foundation
import MoonshineVoice
import VoiceKeyboardCore

@MainActor
final class MoonshineSpeechEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .moonshineMediumStreaming
    let updates: AsyncStream<SpeechEngineUpdate>
    var archiveURL: URL?
    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private let worker = MoonshineLiveWorker()
    private let audioEngine = AVAudioEngine()
    private let converter = AudioBufferConverter()
    private var archive: AudioArchive?
    private var input: AsyncStream<OwnedAudioBuffer>.Continuation?
    private var captureTask: Task<Void, Never>?
    private var tapped = false
    init() {
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        updates = pair.stream; continuation = pair.continuation
    }
    func prepare() async throws {
        continuation.yield(.preparing(message: "Loading Moonshine Medium Streaming…", progress: nil))
        try await worker.prepare(sink: continuation)
    }
    func start() async throws {
        #if targetEnvironment(simulator)
        throw SpeechEngineError.unavailable("Use a physical iPhone for microphone capture.")
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio)
        try session.setActive(true)
        if let archiveURL { archive = try AudioArchive(url: archiveURL) }
        let pair = AsyncStream.makeStream(of: OwnedAudioBuffer.self, bufferingPolicy: .bufferingOldest(64))
        input = pair.continuation
        let sink = continuation
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let owned = OwnedAudioBuffer(buffer) else { return }
            if case .dropped = pair.continuation.yield(owned) {
                sink.yield(.failure(message: "Moonshine could not keep up with audio. Retained audio may be incomplete."))
            }
        }
        tapped = true
        captureTask = Task { [weak self] in
            for await owned in pair.stream {
                guard let self else { return }
                do {
                    try self.archive?.append(owned.buffer)
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    let buffer = try self.converter.convert(owned.buffer, to: format)
                    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                    try await self.worker.feed(samples)
                } catch { self.continuation.yield(.failure(message: error.localizedDescription)); return }
            }
        }
        audioEngine.prepare(); try audioEngine.start()
        #endif
    }
    func stop() async throws {
        if tapped { audioEngine.inputNode.removeTap(onBus: 0); tapped = false }
        audioEngine.stop(); input?.finish()
        await captureTask?.value; captureTask = nil
        archive?.close()
        defer { continuation.finish(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        try await worker.stop()
    }
    func discardCurrentAudio() async throws {
        if tapped { audioEngine.inputNode.removeTap(onBus: 0); tapped = false }
        audioEngine.stop(); input?.finish()
        await captureTask?.value; captureTask = nil
        try await worker.stop()
        archive?.close(); archive = nil
        try await worker.prepare(sink: continuation)
        try await start()
    }
}

private actor MoonshineLiveWorker {
    private var model: Transcriber?
    private var stream: MoonshineVoice.Stream?
    func prepare(sink: AsyncStream<SpeechEngineUpdate>.Continuation) async throws {
        let spec = ModelSpec.stt(language: "en", modelArch: .mediumStreaming)
        let directory = try ModelCache.directory(for: spec)
        try await AssetDownloader().ensureModelPresent(root: directory, spec: spec)
        let model = try Transcriber(modelPath: directory.path, modelArch: .mediumStreaming)
        let stream = try model.createStream(updateInterval: 0.25)
        var delivered: Set<UInt64> = []
        stream.addListener { event in
            if let error = event as? TranscriptError {
                sink.yield(.failure(message: error.error.localizedDescription))
            } else if event is LineCompleted {
                guard delivered.insert(event.line.lineId).inserted else { return }
                sink.yield(.final(text: event.line.text, endOfUtteranceLatencyMilliseconds: Double(event.line.lastTranscriptionLatencyMs), receivedAt: Date()))
            } else if event is LineTextChanged || event is LineStarted {
                sink.yield(.partial(text: event.line.text, receivedAt: Date()))
            }
        }
        try stream.start()
        self.model = model; self.stream = stream
    }
    func feed(_ samples: [Float]) throws { try stream?.addAudio(samples, sampleRate: 16000) }
    func stop() throws { defer { stream = nil; model = nil }; try stream?.stop() }
}
