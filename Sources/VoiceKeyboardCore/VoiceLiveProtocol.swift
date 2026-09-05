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

    public static func configuration() -> [String: Any] {
        ["type": "session.update", "session": [
            "modalities": ["text"],
            "input_audio_format": "pcm16",
            "input_audio_sampling_rate": 16000,
            "input_audio_transcription": ["model": "mai-transcribe"],
            "turn_detection": ["type": "server_vad", "silence_duration_ms": 500,
                               "create_response": false, "interrupt_response": false]
        ]]
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
