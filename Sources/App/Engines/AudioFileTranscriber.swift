@preconcurrency import AVFoundation
import Foundation
import VoiceKeyboardCore

/// File recognition is intentionally independent of microphone ownership.
/// Each comparison gets its own engine instance and never changes an old run.
@MainActor
enum AudioFileTranscriber {
    static let maxDuration = RecordingLimits.maximumDuration

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
