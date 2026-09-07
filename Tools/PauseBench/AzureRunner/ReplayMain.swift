import Foundation
import VoiceKeyboardCore

// Desktop replay of the app protocol: same configuration, accumulator and Stop fence.
// Input is headerless 16 kHz mono signed little-endian PCM16, paced in real time.
@MainActor
final class Replay {
    var state = VoiceLiveTranscript()
    var ready = false
    var stopGate = VoiceLiveStopGate()
    var failure: String?
    var text: [String] = []
    var events: [[String: Any]] = []
    let start = Date()
    let key: String
    let mode: VoiceLiveProtocol.TurnDetection
    init(key: String, mode: VoiceLiveProtocol.TurnDetection) { self.key = key; self.mode = mode }
    func receive(_ data: Data) throws {
        guard var event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        event["bench_elapsed_ms"] = Date().timeIntervalSince(start) * 1000
        events.append(event)
        let id = event["item_id"] as? String ?? ""
        switch type {
        case "session.updated":
            guard VoiceLiveProtocol.confirmsConfiguration(event, turnDetection: mode) else {
                failure = "Service did not confirm transcription-only configuration"; return
            }
            ready = true
        case "input_audio_buffer.committed":
            state.commit(id)
            stopGate.didCommit()
        case "conversation.item.input_audio_transcription.delta":
            state.delta(event["delta"] as? String ?? "", id: id)
        case "conversation.item.input_audio_transcription.completed":
            state.complete(event["transcript"] as? String ?? "", id: id)
        case "input_audio_buffer.cleared": stopGate.didClear()
        case "error", "conversation.item.input_audio_transcription.failed":
            let detail = event["error"] as? [String: Any] ?? [:]
            if detail["code"] as? String == "input_audio_buffer_commit_empty",
               stopGate.didRejectEmptyCommit(eventID: detail["event_id"] as? String) { break }
            failure = String(describing: detail).replacingOccurrences(of: key, with: "[redacted]")
        case "response.created": failure = "Unexpected response generation"
        default: break
        }
        text += state.drain()
    }
    func wait(seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if let failure { throw NSError(domain: failure, code: 1) }
            guard Date() < deadline else { throw NSError(domain: "Replay timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let failure { throw NSError(domain: failure, code: 1) }
    }
}

@main
struct Main {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard (args.count == 4 || args.count == 5), let mode = VoiceLiveProtocol.TurnDetection(rawValue: args[1]) else {
            fputs("Usage: pause-bench-azure <legacy500|server1500|server2000|azureSemantic> <audio.pcm> <result.json> [packet-schedule.json]\n", stderr)
            exit(2)
        }
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AZURE_SPEECH_KEY"], !key.isEmpty,
              let endpoint = env["AZURE_SPEECH_ENDPOINT"], !endpoint.isEmpty else {
            fputs("Set AZURE_SPEECH_KEY and AZURE_SPEECH_ENDPOINT.\n", stderr); exit(2)
        }
        let replay = Replay(key: key, mode: mode)
        var result: [String: Any] = ["profile": mode.rawValue, "configuration": VoiceLiveProtocol.configuration(turnDetection: mode)]
        do {
            let pcm = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            guard !pcm.isEmpty, pcm.count % 2 == 0 else { throw NSError(domain: "Invalid PCM16 input", code: 1) }
            var request = URLRequest(url: try VoiceLiveProtocol.endpoint(endpoint))
            request.setValue(key, forHTTPHeaderField: "api-key")
            let session = URLSession(configuration: .ephemeral)
            let socket = session.webSocketTask(with: request)
            socket.resume()
            let receiver = Task { @MainActor in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        switch message {
                        case .string(let value): try replay.receive(Data(value.utf8))
                        case .data(let value): try replay.receive(value)
                        @unknown default: break
                        }
                    }
                } catch { replay.failure = error.localizedDescription }
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Double(pcm.count) / 32000 + 75))
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            defer {
                receiver.cancel(); watchdog.cancel()
                socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel()
            }
            func send(_ event: [String: Any]) async throws {
                let data = try JSONSerialization.data(withJSONObject: event)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
            try await send(VoiceLiveProtocol.configuration(turnDetection: mode))
            try await replay.wait(seconds: 20) { replay.ready }
            let audioStart = Date()
            result["audio_start_ms"] = audioStart.timeIntervalSince(replay.start) * 1000
            struct Packet: Decodable { let at_ms: Double; let audio: String }
            let packets: [Packet]
            if args.count == 5 {
                packets = try JSONDecoder().decode([Packet].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
                result["audio_schedule"] = args[4]
            } else {
                packets = stride(from: 0, to: pcm.count, by: 640).map { offset in
                    let end = min(offset + 640, pcm.count)
                    return Packet(at_ms: Double(end) / 32, audio: pcm[offset..<end].base64EncodedString())
                }
            }
            var previousTime = 0.0
            for packet in packets {
                guard packet.at_ms >= previousTime, packet.at_ms <= Double(pcm.count) / 32,
                      Data(base64Encoded: packet.audio) != nil else {
                    throw NSError(domain: "Invalid audio schedule", code: 1)
                }
                previousTime = packet.at_ms
                if let failure = replay.failure { throw NSError(domain: failure, code: 1) }
                // Preserve original capture time even when a local VAD drops frames.
                let delay = packet.at_ms / 1000 - Date().timeIntervalSince(audioStart)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try await send(["type": "input_audio_buffer.append", "audio": packet.audio])
            }
            let remaining = Double(pcm.count) / 32000 - Date().timeIntervalSince(audioStart)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            result["stop_ms"] = Date().timeIntervalSince(replay.start) * 1000
            let commitID = UUID().uuidString
            replay.stopGate.begin(commitID: commitID)
            try await send(["type": "input_audio_buffer.commit", "event_id": commitID])
            try await replay.wait(seconds: 30) { replay.stopGate.canClear(transcriptionPending: replay.state.isPending) }
            try await send(["type": "input_audio_buffer.clear"])
            try await replay.wait(seconds: 30) { replay.stopGate.canFinish(transcriptionPending: replay.state.isPending) }
            result["status"] = "ok"
            result["text"] = replay.text.joined(separator: " ")
        } catch {
            result["status"] = "error"
            result["error"] = error.localizedDescription.replacingOccurrences(of: key, with: "[redacted]")
        }
        result["elapsed_ms"] = Date().timeIntervalSince(replay.start) * 1000
        result["events"] = replay.events
        do {
            let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let safe = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: key, with: "[redacted]")
            try Data(safe.utf8).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        } catch { fputs("Unable to write benchmark result.\n", stderr); exit(1) }
        if result["status"] as? String != "ok" { exit(1) }
    }
}
