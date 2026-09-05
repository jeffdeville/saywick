@preconcurrency import AVFoundation
import Foundation
import UIKit
import VoiceKeyboardCore

private final class LiveAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let capturedAt = Date()
    init?(_ source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in input.indices {
            guard let src = input[i].mData, let dst = output[i].mData else { return nil }
            memcpy(dst, src, Int(input[i].mDataByteSize))
        }
        buffer = copy
    }
}

@MainActor
final class MAIVoiceLiveEngine: LiveSpeechEngine {
    let id: SpeechEngineID = .maiVoiceLive
    var archiveURL: URL?
    private var archive: AudioArchive?
    let updates: AsyncStream<SpeechEngineUpdate>
    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private let endpoint: String
    private let key: String
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private let audioEngine = AVAudioEngine()
    private let converter = AudioBufferConverter()
    private var audioContinuation: AsyncStream<LiveAudioBuffer>.Continuation?
    private var transcript = VoiceLiveTranscript()
    private var ready = false
    private var closed = false
    private var tapped = false
    private var stopping = false
    private var streamError: Error?
    private var stopFence = false
    private var stopCommitID: String?
    private var audioCutoff = Date.distantPast

    init(endpoint: String, key: String) {
        self.endpoint = endpoint
        self.key = key
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        updates = pair.stream
        continuation = pair.continuation
    }

    func prepare() async throws {
        guard !key.isEmpty else { throw SpeechEngineError.unavailable("Save your Azure Speech key in Azure connection first.") }
        var request = URLRequest(url: try VoiceLiveProtocol.endpoint(endpoint))
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 20
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, !self.closed else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    try self.receive(data)
                } catch {
                    guard let self, !self.closed else { return }
                    self.report(error)
                    return
                }
            }
        }
        try await enqueue(VoiceLiveProtocol.configuration()).value
        try await waitUntil("Azure did not confirm the MAI Live session.", seconds: 20) { self.ready }
    }

    func start() async throws {
        #if targetEnvironment(simulator)
        throw SpeechEngineError.unavailable("Use your iPhone for live microphone capture. The connection test works without a microphone.")
        #else
        guard ready else { throw SpeechEngineError.notPrepared }
        if let archiveURL { archive = try AudioArchive(url: archiveURL) }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .spokenAudio)
        try audioSession.setActive(true)
        let pair = AsyncStream.makeStream(of: LiveAudioBuffer.self, bufferingPolicy: .bufferingOldest(64))
        audioContinuation = pair.continuation
        let stream = pair.stream
        let audioSink = pair.continuation
        let eventSink = continuation
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let owned = LiveAudioBuffer(buffer) else {
                eventSink.yield(.failure(message: "Could not copy microphone audio.")); return
            }
            if case .dropped = audioSink.yield(owned) {
                eventSink.yield(.failure(message: "The connection cannot keep up with audio. Please try again on a faster network."))
            }
        }
        tapped = true
        sender = Task { [weak self] in
            for await owned in stream {
                guard let self, !self.closed else { return }
                if self.transcript.isClearing || owned.capturedAt <= self.audioCutoff { continue }
                do {
                    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
                    let converted = try self.converter.convert(owned.buffer, to: format)
                    try self.archive?.append(converted)
                    guard let samples = converted.int16ChannelData?[0], converted.frameLength > 0 else { continue }
                    try await self.sendAudio(Data(bytes: samples, count: Int(converted.frameLength) * 2))
                } catch { self.report(error); return }
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        #endif
    }

    func sendAudio(_ data: Data) async throws {
        try await enqueue(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]).value
    }

    func discardCurrentAudio() {
        guard !transcript.isClearing, !closed else { return }
        audioCutoff = Date()
        do { try archive?.reset() }
        catch { report(error); return }
        transcript.beginClear()
        let task = enqueue(["type": "input_audio_buffer.clear"])
        Task { [weak self] in
            do { try await task.value }
            catch { self?.report(error) }
        }
    }

    func stop() async throws {
        guard !closed else {
            if let streamError { throw streamError }
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Finish MAI Live") { [weak self] in
            Task { @MainActor in self?.report(SpeechEngineError.unavailable("iOS ended background transcription. Keep the recorder open to finish.")) }
        }
        defer {
            cancel()
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        stopMicrophone()
        await sender?.value
        if let streamError { throw streamError }
        try await waitUntil("Azure did not acknowledge Clear.", seconds: 10) { !self.transcript.isClearing }
        stopping = true
        stopFence = false
        let commitID = UUID().uuidString
        stopCommitID = commitID
        try await enqueue(["type": "input_audio_buffer.commit", "event_id": commitID]).value
        // Clear is a server-acknowledged fence after all sent audio and the final
        // commit. Any in-flight transcription is still awaited separately.
        try await enqueue(["type": "input_audio_buffer.clear"]).value
        try await waitUntil("Azure did not finish the transcript. Please retry.", seconds: 25) {
            self.stopFence && !self.transcript.isPending
        }
        // Drain app-level events explicitly through the caller's update task.
        continuation.finish()
    }

    func cancel() {
        archive?.close()
        closed = true
        stopMicrophone()
        sender?.cancel()
        receiver?.cancel()
        sendTail?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopMicrophone() {
        if tapped { audioEngine.inputNode.removeTap(onBus: 0); tapped = false }
        audioEngine.stop()
        audioContinuation?.finish()
    }

    private func enqueue(_ event: [String: Any]) -> Task<Void, Error> {
        let prior = sendTail
        let socket = self.socket
        let encoded = Result { String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) }
        let task = Task { @MainActor in
            try await prior?.value
            try Task.checkCancellation()
            guard let socket else { throw SpeechEngineError.notPrepared }
            // URLRequest's timeout does not reliably bound WebSocket sends.
            // Close a stalled connection so Stop cannot wait forever for audio.
            let watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { watchdog.cancel() }
            try await socket.send(.string(try encoded.get()))
        }
        sendTail = task
        return task
    }

    private func receive(_ data: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let id = event["item_id"] as? String ?? ""
        switch type {
        case "session.updated":
            guard let settings = event["session"] as? [String: Any],
                  let recognition = settings["input_audio_transcription"] as? [String: Any],
                  recognition["model"] as? String == "mai-transcribe",
                  let vad = settings["turn_detection"] as? [String: Any],
                  vad["create_response"] as? Bool == false else {
                throw SpeechEngineError.unavailable("Azure did not confirm MAI transcription with replies disabled.")
            }
            ready = true
        case "input_audio_buffer.committed":
            transcript.commit(id)
        case "conversation.item.input_audio_transcription.delta":
            transcript.delta(event["delta"] as? String ?? "", id: id)
        case "conversation.item.input_audio_transcription.completed":
            transcript.complete(event["transcript"] as? String ?? "", id: id)
        case "input_audio_buffer.cleared":
            transcript.finishClear()
            if stopping { stopFence = true }
        case "error", "conversation.item.input_audio_transcription.failed":
            let detail = event["error"] as? [String: Any] ?? [:]
            let code = detail["code"] as? String ?? "unknown"
            if stopping, code == "input_audio_buffer_commit_empty", detail["event_id"] as? String == stopCommitID { return }
            let message = (detail["message"] as? String ?? "Check Azure resource access and network.")
                .replacingOccurrences(of: key, with: "[redacted]")
            throw SpeechEngineError.unavailable("MAI Live: \(message)")
        case "response.created":
            _ = enqueue(["type": "response.cancel"])
            throw SpeechEngineError.unavailable("Azure unexpectedly generated a reply. The session was stopped.")
        default: return
        }
        for text in transcript.drain() {
            continuation.yield(.final(text: text, endOfUtteranceLatencyMilliseconds: nil, receivedAt: Date()))
        }
        continuation.yield(.partial(text: transcript.partialText, receivedAt: Date()))
    }

    private func report(_ error: Error) {
        guard streamError == nil else { return }
        streamError = error
        continuation.yield(.failure(message: error.localizedDescription))
    }

    private func waitUntil(_ message: String, seconds: Double, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if let streamError { throw streamError }
            try Task.checkCancellation()
            guard !closed, Date() < deadline else { throw SpeechEngineError.unavailable(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let streamError { throw streamError }
    }
}
