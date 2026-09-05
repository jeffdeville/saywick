@preconcurrency import AVFoundation
import Foundation
import Speech
import MoonshineVoice
import VoiceKeyboardCore

/// File recognition is intentionally independent of microphone ownership.
/// Each comparison gets its own engine instance and never changes an old run.
@MainActor
enum AudioFileTranscriber {
    static let maxDuration: Double = 25 * 60

    static func normalizedCopy(from source: URL, to destination: URL) async throws {
        let file = try AVAudioFile(forReading: source)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration <= maxDuration else {
            throw SpeechEngineError.unavailable("Choose a nonempty recording under 25 minutes. Long meetings are not supported yet.")
        }
        let output = try AudioArchive(url: destination)
        defer { output.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw SpeechEngineError.unavailable("Could not allocate audio import buffer.")
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            try output.append(buffer)
            await Task.yield()
        }
    }

    static func transcribe(_ url: URL, engine: SpeechEngineID,
                           progress: @escaping @MainActor (String) -> Void) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= maxDuration else {
            throw SpeechEngineError.unavailable("File comparison is limited to 25 minutes.")
        }
        switch engine {
        case .maiTranscribe2:
            progress("Uploading retained audio to Microsoft…")
            return try await batch(url)
        case .maiVoiceLive:
            let live = MAIVoiceLiveEngine(endpoint: UserDefaults.standard.string(forKey: "azureSpeechEndpoint") ?? "",
                                          key: AzureCredentialStore.read())
            defer { live.cancel() }
            let collector = Task { @MainActor in
                var text: [String] = []
                for await update in live.updates {
                    if case .final(let value, _, _) = update { text.append(value) }
                }
                return text.joined(separator: " ")
            }
            defer { collector.cancel() }
            try await live.prepare()
            let converter = AudioBufferConverter()
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                let converted = try converter.convert(buffer, to: AudioArchive.format)
                if let samples = converted.int16ChannelData?[0] {
                    try await live.sendAudio(Data(bytes: samples, count: Int(converted.frameLength) * 2))
                }
                progress("Replaying to MAI Live: \(Int(Double(file.framePosition) / Double(file.length) * 100))% — realtime pacing")
                try await Task.sleep(for: .seconds(Double(buffer.frameLength) / buffer.format.sampleRate))
            }
            try await live.stop()
            return await collector.value
        case .appleSpeechAnalyzer:
            progress("Preparing Apple’s on-device model…")
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
                throw SpeechEngineError.englishUnavailable
            }
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await install.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            let results = Task { @MainActor in
                var text: [String] = []
                for try await result in module.results where result.isFinal {
                    text.append(String(result.text.characters))
                }
                return text.joined(separator: " ")
            }
            do {
                progress("Transcribing file on device…")
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await results.value
            } catch {
                await analyzer.cancelAndFinishNow(); results.cancel(); throw error
            }
        case .moonshineMediumStreaming:
            progress("Loading Moonshine; comparison runs on device…")
            return try await MoonshineFileWorker().transcribe(url)
        }
    }

    private static func batch(_ url: URL) async throws -> String {
        let key = AzureCredentialStore.read()
        guard !key.isEmpty else { throw SpeechEngineError.unavailable("Save an Azure key first.") }
        let boundary = UUID().uuidString
        var request = URLRequest(url: try MAITranscriptionAPI.endpoint(UserDefaults.standard.string(forKey: "azureSpeechEndpoint") ?? ""))
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = MAITranscriptionAPI.multipart(audio: try Data(contentsOf: url), boundary: boundary)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpeechEngineError.unavailable("Azure rejected the file (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check your key, region, and quota. Audio remains in History.")
        }
        return try MAITranscriptionAPI.transcript(from: data)
    }
}

/// Keeps synchronous native inference off the UI executor.
actor MoonshineFileWorker {
    func transcribe(_ url: URL) async throws -> String {
        let spec = ModelSpec.stt(language: "en", modelArch: .mediumStreaming)
        let directory = try ModelCache.directory(for: spec)
        try await AssetDownloader().ensureModelPresent(root: directory, spec: spec)
        try Task.checkCancellation()
        let model = try Transcriber(modelPath: directory.path, modelArch: .mediumStreaming)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let stream = try model.createStream(updateInterval: 0.5)
        var lines: [UInt64: String] = [:]
        var order: [UInt64] = []
        stream.addListener { event in
            if event is LineCompleted {
                if lines[event.line.lineId] == nil { order.append(event.line.lineId) }
                lines[event.line.lineId] = event.line.text
            }
        }
        try stream.start()
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000)!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            try stream.addAudio(samples, sampleRate: Int32(file.processingFormat.sampleRate))
        }
        try stream.stop()
        return order.compactMap { lines[$0] }.joined(separator: " ")
    }
}
