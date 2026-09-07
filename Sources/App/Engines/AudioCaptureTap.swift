@preconcurrency import AVFoundation
import VoiceKeyboardCore

/// AVAudioEngine invokes taps on its audio queue. Explicit Sendable isolation
/// prevents a tap created by a main-actor engine from inheriting that actor.
enum AudioCaptureTap {
    static func make<Buffer: Sendable>(
        copy: @escaping @Sendable (AVAudioPCMBuffer) -> Buffer?,
        audio: AsyncStream<Buffer>.Continuation,
        events: AsyncStream<SpeechEngineUpdate>.Continuation,
        overflowMessage: String
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in
            guard let owned = copy(buffer) else {
                events.yield(.failure(message: "Could not copy microphone audio."))
                return
            }
            if case .dropped = audio.yield(owned) {
                events.yield(.failure(message: overflowMessage))
            }
        }
    }
}
