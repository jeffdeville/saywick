@preconcurrency import AVFoundation
import Foundation
import VoiceKeyboardCore

/// File recognition is intentionally independent of microphone ownership.
/// Each comparison gets its own engine instance and never changes an old run.
@MainActor
enum AudioFileTranscriber {
    static let maxDuration = RecordingLimits.maximumDuration

    static func normalizedCopy(from source: URL, to destination: URL) async throws {
        let file = try AVAudioFile(forReading: source)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration <= maxDuration else {
            throw SpeechEngineError.unavailable("Choose a nonempty recording no longer than 4 hours.")
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
            throw SpeechEngineError.unavailable("File transcription is limited to 4 hours.")
        }
        guard engine == .parakeetStreaming else {
            throw SpeechEngineError.unavailable("This engine is no longer available. Transcribe retained audio with Parakeet instead.")
        }
        progress("Preparing Parakeet; first use downloads 731 MB…")
        let modelURL = try await ParakeetModelStore.shared.modelURL()
        progress("Transcribing audio with Parakeet on this iPhone…")
        return try await ParakeetWorker().transcribe(url, modelURL: modelURL)
    }
}
