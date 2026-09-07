@preconcurrency import AVFoundation
import Foundation
import TranscribeCpp

/// All native work and handles stay on this actor, never the audio callback or UI.
actor ParakeetWorker {
    private var model: Model?
    private var stream: TranscribeCpp.Stream?

    func prepare(modelURL: URL, backend: Backend = .cpuAccel) throws {
        cancel()
        let loaded = try Model(path: modelURL.path, options: ModelOptions(backend: backend))
        let session = try loaded.session(SessionOptions(nThreads: 4))
        // Handy's default native context/commit policy; pauses never reset the decoder.
        stream = try session.stream()
        model = loaded
    }

    func feed(_ samples: [Float]) throws -> String? {
        guard let stream else { throw SpeechEngineError.notPrepared }
        let update = try stream.feed(samples)
        return update.resultChanged ? stream.text.full : nil
    }

    func finish() throws -> String {
        guard let stream else { return "" }
        defer { self.stream = nil; model = nil }
        try stream.finalize()
        return stream.text.full
    }

    func cancel() {
        stream?.reset()
        stream = nil; model = nil
    }

    func transcribe(_ url: URL, modelURL: URL) throws -> String {
        try prepare(modelURL: modelURL)
        defer { cancel() }
        let file = try AVAudioFile(forReading: url)
        let converter = AudioBufferConverter()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let converted = try converter.convert(buffer, to: format)
            _ = try feed(Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))))
        }
        return try finish()
    }
}
