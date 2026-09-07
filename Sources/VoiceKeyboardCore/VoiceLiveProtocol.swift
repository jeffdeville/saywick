import Foundation

public enum VoiceLiveProtocol {
    public static func endpoint(_ source: String) throws -> URL {
        let validated = try MAITranscriptionAPI.endpoint(source)
        var parts = URLComponents(url: validated, resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        parts.path = "/voice-live/realtime"
        parts.queryItems = [
            URLQueryItem(name: "api-version", value: "2026-04-10"),
            URLQueryItem(name: "model", value: "gpt-5-nano")
        ]
        return parts.url!
    }

    /// A thinking pause should not immediately become a completed speech turn.
    /// Semantic detection remains an explicit benchmark candidate until validated.
    public enum TurnDetection: String, CaseIterable, Sendable {
        case legacy500, server1500, server2000, azureSemantic

        public var settings: [String: Any] {
            switch self {
            case .legacy500: return server(milliseconds: 500)
            case .server1500: return server(milliseconds: 1500)
            case .server2000: return server(milliseconds: 2000)
            case .azureSemantic:
                return ["type": "azure_semantic_vad", "silence_duration_ms": 1500,
                        "create_response": false, "interrupt_response": false]
            }
        }

        private func server(milliseconds: Int) -> [String: Any] {
            ["type": "server_vad", "silence_duration_ms": milliseconds,
             "create_response": false, "interrupt_response": false]
        }
    }

    public static func configuration(turnDetection: TurnDetection = .server1500) -> [String: Any] {
        ["type": "session.update", "session": [
            "modalities": ["text"],
            "input_audio_format": "pcm16",
            "input_audio_sampling_rate": 16000,
            "input_audio_transcription": ["model": "mai-transcribe"],
            "turn_detection": turnDetection.settings
        ]]
    }

    public static func confirmsConfiguration(_ event: [String: Any],
                                             turnDetection: TurnDetection = .server1500) -> Bool {
        guard let session = event["session"] as? [String: Any],
              let recognition = session["input_audio_transcription"] as? [String: Any],
              recognition["model"] as? String == "mai-transcribe",
              let vad = session["turn_detection"] as? [String: Any] else { return false }
        return vad["create_response"] as? Bool == false
            && vad["type"] as? String == turnDetection.settings["type"] as? String
            && vad["silence_duration_ms"] as? Int == turnDetection.settings["silence_duration_ms"] as? Int
    }
}

/// Preserve commit order even when transcription completions arrive out of order.
/// A completed event replaces its deltas; it must never be appended to them.
public struct VoiceLiveTranscript: Sendable {
    private var order: [String] = []
    private var completed: [String: String] = [:]
    private var partials: [String: String] = [:]
    private var delivered: Set<String> = []
    private var ignored: Set<String> = []
    public private(set) var isClearing = false
    public init() {}

    public var isPending: Bool { order.contains { !delivered.contains($0) && !ignored.contains($0) } }
    public var partialText: String {
        order.filter { !delivered.contains($0) && !ignored.contains($0) }
            .compactMap { completed[$0] ?? partials[$0] }.joined(separator: " ")
    }
    public mutating func commit(_ id: String) {
        if isClearing { ignored.insert(id) }
        if !order.contains(id) { order.append(id) }
    }
    public mutating func delta(_ text: String, id: String) {
        if isClearing { ignored.insert(id) }
        guard !ignored.contains(id), !delivered.contains(id), completed[id] == nil else { return }
        partials[id, default: ""] += text
    }
    public mutating func complete(_ text: String, id: String) {
        if isClearing { ignored.insert(id) }
        guard !ignored.contains(id), !delivered.contains(id) else { return }
        completed[id] = text
        partials[id] = nil
    }
    public mutating func drain() -> [String] {
        var result: [String] = []
        for id in order where !ignored.contains(id) && !delivered.contains(id) {
            guard let text = completed[id] else { break }
            delivered.insert(id)
            result.append(text)
        }
        return result
    }
    public mutating func beginClear() {
        ignored.formUnion(order)
        ignored.formUnion(partials.keys)
        ignored.formUnion(completed.keys)
        partials.removeAll()
        completed.removeAll()
        isClearing = true
    }
    public mutating func finishClear() { isClearing = false }
}

/// Voice Live processes Commit asynchronously. A Clear acknowledgement must not
/// finish Stop before Commit was acknowledged and its transcription was drained.
public struct VoiceLiveStopGate: Sendable {
    public private(set) var commitID: String?
    private var commitAcknowledged = false
    private var clearAcknowledged = false

    public init() {}

    public mutating func begin(commitID: String) {
        self.commitID = commitID
        commitAcknowledged = false
        clearAcknowledged = false
    }

    public mutating func didCommit() {
        if commitID != nil { commitAcknowledged = true }
    }

    /// Azure can omit event_id on an empty-buffer reply. We issue only one client
    /// Commit (at Stop), so an uncorrelated empty reply is valid while Stop is active.
    /// A reply explicitly correlated to another request must still be rejected.
    public mutating func didRejectEmptyCommit(eventID: String?) -> Bool {
        guard let commitID, eventID == nil || eventID == commitID else { return false }
        commitAcknowledged = true
        return true
    }

    public mutating func didClear() { clearAcknowledged = true }

    public func canClear(transcriptionPending: Bool) -> Bool {
        commitAcknowledged && !transcriptionPending
    }

    public func canFinish(transcriptionPending: Bool) -> Bool {
        canClear(transcriptionPending: transcriptionPending) && clearAcknowledged
    }
}
