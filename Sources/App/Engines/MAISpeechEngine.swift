@preconcurrency import AVFoundation
import Foundation
import UIKit
import VoiceKeyboardCore

@MainActor
final class MAISpeechEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .maiTranscribe2
    var archiveURL: URL?
    let updates: AsyncStream<SpeechEngineUpdate>
    private(set) var completedTranscript: String?
    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private let endpoint: String
    private let key: String
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var upload: Task<(Data, URLResponse), Error>?

    init(endpoint: String, key: String) {
        self.endpoint = endpoint
        self.key = key
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        updates = pair.stream
        continuation = pair.continuation
    }

    func prepare() async throws {
        _ = try MAITranscriptionAPI.endpoint(endpoint)
        guard !key.isEmpty else {
            throw SpeechEngineError.unavailable("Add your Azure Speech key in the app’s Azure connection settings.")
        }
    }

    func start() async throws {
        #if targetEnvironment(simulator)
        throw SpeechEngineError.unavailable("Test microphone recording on your iPhone. Simulator demo tests use synthetic transcripts.")
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio)
        try session.setActive(true)
        let url = archiveURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("mai-\(UUID().uuidString).wav")
        audioURL = url
        let candidate = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        recorder = candidate
        guard candidate.record() else {
            throw SpeechEngineError.unavailable("Microphone recording could not start.")
        }
        #endif
    }

    func discardCurrentAudio() throws {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        guard recorder.record() else {
            throw SpeechEngineError.unavailable("Could not restart microphone recording.")
        }
    }

    func cancel() {
        upload?.cancel()
        recorder?.stop()
        recorder = nil
        if let audioURL, archiveURL == nil { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stop() async throws {
        guard let recorder, let audioURL else { return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "MAI transcription") { [weak self] in
            Task { @MainActor in self?.upload?.cancel() }
        }
        defer {
            cancel()
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        recorder.stop()
        continuation.yield(.preparing(message: "Transcribing with Microsoft…", progress: nil))
        let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 50_000_000 else {
            throw SpeechEngineError.unavailable("Recording is too long for this dictation mode. Keep each recording under 25 minutes.")
        }
        let boundary = "LocalVoice-\(UUID().uuidString)"
        var request = URLRequest(url: try MAITranscriptionAPI.endpoint(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = MAITranscriptionAPI.multipart(audio: try Data(contentsOf: audioURL), boundary: boundary)
        let task = Task { try await URLSession.shared.upload(for: request, from: body) }
        upload = task
        let (data, response) = try await task.value
        guard let http = response as? HTTPURLResponse else {
            throw SpeechEngineError.unavailable("Azure returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let hint: String
            switch http.statusCode {
            case 401, 403: hint = "Check your Azure Speech key and resource access."
            case 400, 404: hint = "Check the endpoint and that MAI-Transcribe-2 is available in your resource’s region."
            case 429: hint = "Azure quota exceeded. Try again later."
            default: hint = "Try again later."
            }
            throw SpeechEngineError.unavailable("Azure transcription failed (HTTP \(http.statusCode)). \(hint)")
        }
        // Read synchronously after stop(), avoiding a race with the event consumer.
        completedTranscript = try MAITranscriptionAPI.transcript(from: data)
        continuation.finish()
    }
}
