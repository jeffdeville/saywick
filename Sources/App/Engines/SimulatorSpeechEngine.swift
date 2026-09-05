#if targetEnvironment(simulator)
import Foundation
import VoiceKeyboardCore

@MainActor
final class SimulatorSpeechEngine: LiveSpeechEngine {
    let id: SpeechEngineID
    let updates: AsyncStream<SpeechEngineUpdate>
    let requiresMicrophoneAuthorization = false
    var archiveURL: URL?

    private let continuation: AsyncStream<SpeechEngineUpdate>.Continuation
    private var playbackTask: Task<Void, Never>?

    init(representing id: SpeechEngineID) {
        self.id = id
        let pair = AsyncStream.makeStream(of: SpeechEngineUpdate.self)
        self.updates = pair.stream
        self.continuation = pair.continuation
    }

    func prepare() async throws {
        continuation.yield(
            .preparing(message: "Simulator demo is ready", progress: 1)
        )
    }

    func start() async throws {
        playbackTask?.cancel()
        let continuation = self.continuation
        playbackTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            continuation.yield(
                .partial(text: "hello from the local voice simulator", receivedAt: Date())
            )

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            continuation.yield(
                .partial(
                    text: "hello from the local voice simulator this transcript stayed on device",
                    receivedAt: Date()
                )
            )
        }
    }

    func stop() async throws {
        playbackTask?.cancel()
        playbackTask = nil
        continuation.yield(
            .final(
                text: "hello from the local voice simulator this transcript stayed on device",
                endOfUtteranceLatencyMilliseconds: 42,
                receivedAt: Date()
            )
        )
        try? await Task.sleep(for: .milliseconds(20))
        continuation.finish()
    }
}
#endif
