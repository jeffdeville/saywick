import Foundation
import VoiceKeyboardCore

@MainActor
protocol LiveSpeechEngine: AnyObject {
    var id: SpeechEngineID { get }
    var updates: AsyncStream<SpeechEngineUpdate> { get }
    var requiresMicrophoneAuthorization: Bool { get }
    var archiveURL: URL? { get set }

    func prepare() async throws
    func start() async throws
    func stop() async throws
    func cancel() async
}

extension LiveSpeechEngine {
    var requiresMicrophoneAuthorization: Bool { true }
    var archiveURL: URL? { get { nil } set {} }
}

enum SpeechEngineError: LocalizedError {
    case microphoneDenied
    case englishUnavailable
    case notPrepared
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required. Enable it in Settings > Privacy & Security > Microphone."
        case .englishUnavailable:
            "An English on-device speech model is not available on this OS build."
        case .notPrepared:
            "The speech engine has not finished preparing."
        case .unavailable(let message):
            message
        }
    }
}

@MainActor
enum LiveSpeechEngineFactory {
    static func make(allowModelDownload: Bool = true) -> any LiveSpeechEngine {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["LOCAL_VOICE_SIMULATOR_DEMO"] == "1" {
            return SimulatorSpeechEngine(representing: .parakeetStreaming)
        }
        #endif

        return ParakeetSpeechEngine(allowModelDownload: allowModelDownload)
    }
}
