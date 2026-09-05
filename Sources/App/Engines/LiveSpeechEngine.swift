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
    func discardCurrentAudio() async throws
}

extension LiveSpeechEngine {
    var requiresMicrophoneAuthorization: Bool { true }
    var archiveURL: URL? { get { nil } set {} }
    func discardCurrentAudio() async throws {}
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
    static func make(_ id: SpeechEngineID) -> any LiveSpeechEngine {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["LOCAL_VOICE_SIMULATOR_DEMO"] == "1" {
            return SimulatorSpeechEngine(representing: id)
        }
        #endif

        switch id {
        case .maiVoiceLive:
            return MAIVoiceLiveEngine(
                endpoint: UserDefaults.standard.string(forKey: "azureSpeechEndpoint") ?? "",
                key: AzureCredentialStore.read()
            )
        case .maiTranscribe2:
            return MAISpeechEngine(
                endpoint: UserDefaults.standard.string(forKey: "azureSpeechEndpoint") ?? "",
                key: AzureCredentialStore.read()
            )
        case .appleSpeechAnalyzer:
            return AppleSpeechAnalyzerEngine()
        case .moonshineMediumStreaming:
            return MoonshineSpeechEngine()
        }
    }
}
