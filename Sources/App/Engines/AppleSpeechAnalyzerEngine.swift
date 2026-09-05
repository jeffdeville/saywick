@preconcurrency import AVFoundation
import Foundation
import Speech
import VoiceKeyboardCore

@MainActor
final class AppleSpeechAnalyzerEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .appleSpeechAnalyzer
    var archiveURL: URL?
    private var archive: AudioArchive?
    let updates: AsyncStream<SpeechEngineUpdate>

    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureContinuation: AsyncStream<OwnedAudioBuffer>.Continuation?
    private let audioEngine = AVAudioEngine()
    private let converter = AudioBufferConverter()
    private var isRunning = false
    private var tapIsInstalled = false

    init() {
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        self.updates = pair.stream
        self.continuation = pair.continuation
    }

    func prepare() async throws {
        guard transcriber == nil else { return }
        continuation.yield(.preparing(message: "Checking Apple’s English speech model…", progress: nil))

        let requested = Locale(identifier: "en_US")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        guard let locale else { throw SpeechEngineError.englishUnavailable }

        let candidate = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [candidate]) {
            continuation.yield(.preparing(message: "Downloading Apple’s English speech model…", progress: nil))
            try await installation.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)

        let analyzer = SpeechAnalyzer(modules: [candidate])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [candidate])
        guard let format else {
            throw SpeechEngineError.unavailable("Apple SpeechAnalyzer did not provide a compatible audio format.")
        }
        try await analyzer.prepareToAnalyze(in: format)

        self.transcriber = candidate
        self.analyzer = analyzer
        self.analyzerFormat = format
        continuation.yield(.preparing(message: "Apple SpeechAnalyzer is ready", progress: 1))
    }

    func start() async throws {
        #if targetEnvironment(simulator)
        throw SpeechEngineError.unavailable(
            "Apple SpeechAnalyzer loaded, but live microphone capture must be tested on a physical iPhone."
        )
        #else
        guard !isRunning else { return }
        guard let transcriber, let analyzer, analyzerFormat != nil else {
            throw SpeechEngineError.notPrepared
        }
        guard await microphoneIsAuthorized() else {
            throw SpeechEngineError.microphoneDenied
        }

        try configureAudioSession()
        if let archiveURL { archive = try AudioArchive(url: archiveURL) }

        let inputPair = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = inputPair.continuation

        let continuation = self.continuation
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        continuation.yield(
                            .final(
                                text: text,
                                endOfUtteranceLatencyMilliseconds: nil,
                                receivedAt: Date()
                            )
                        )
                    } else {
                        continuation.yield(.partial(text: text, receivedAt: Date()))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.failure(message: error.localizedDescription))
            }
        }

        do {
            try await analyzer.start(inputSequence: inputPair.stream)
            try startCapture()
            isRunning = true
        } catch {
            if tapIsInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                tapIsInstalled = false
            }
            audioEngine.stop()
            captureContinuation?.finish()
            captureTask?.cancel()
            captureTask = nil
            captureContinuation = nil
            inputBuilder?.finish()
            await analyzer.cancelAndFinishNow()
            resultTask?.cancel()
            resultTask = nil
            inputBuilder = nil
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            throw error
        }
        #endif
    }

    func stop() async throws {
        guard isRunning else { return }
        isRunning = false

        if tapIsInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
        audioEngine.stop()
        captureContinuation?.finish()
        await captureTask?.value
        archive?.close()
        captureTask = nil
        captureContinuation = nil

        inputBuilder?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultTask?.value
        resultTask = nil
        inputBuilder = nil

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )

        // A SpeechAnalyzer session is single-use. Prepare a fresh one next time.
        transcriber = nil
        analyzer = nil
        analyzerFormat = nil
        continuation.finish()
    }

    private func startCapture() throws {
        let capturePair = AsyncStream.makeStream(
            of: OwnedAudioBuffer.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        captureContinuation = capturePair.continuation

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputNode.outputFormat(forBus: 0)
        ) { buffer, _ in
            if let owned = OwnedAudioBuffer(buffer) { capturePair.continuation.yield(owned) }
        }
        tapIsInstalled = true

        captureTask = Task { [weak self] in
            for await captured in capturePair.stream {
                guard let self else { return }
                do {
                    try self.archive?.append(captured.buffer)
                    try self.send(captured.buffer)
                } catch {
                    self.continuation.yield(.failure(message: error.localizedDescription))
                    return
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func discardCurrentAudio() async throws {
        if tapIsInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapIsInstalled = false }
        audioEngine.stop(); captureContinuation?.finish()
        await captureTask?.value; captureTask = nil
        inputBuilder?.finish()
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel(); await resultTask?.value
        archive?.close(); archive = nil
        transcriber = nil; analyzer = nil; analyzerFormat = nil; isRunning = false
        try await prepare()
        try await start()
    }

    private func send(_ buffer: AVAudioPCMBuffer) throws {
        guard let inputBuilder, let analyzerFormat else {
            throw SpeechEngineError.notPrepared
        }
        let converted = try converter.convert(buffer, to: analyzerFormat)
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func microphoneIsAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
