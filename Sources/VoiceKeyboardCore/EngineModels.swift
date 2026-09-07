import Foundation

public enum SpeechEngineID: String, CaseIterable, Codable, Identifiable, Sendable {
    case maiTranscribe2
    case maiVoiceLive
    case appleSpeechAnalyzer
    case moonshineMediumStreaming
    case parakeetStreaming

    // Legacy cases are retained only for saved History and benchmark compatibility.
    public static let allCases: [SpeechEngineID] = [.parakeetStreaming]

    public var id: String { rawValue }
    public var isCloud: Bool { self == .maiTranscribe2 || self == .maiVoiceLive }

    public var displayName: String {
        switch self {
        case .maiVoiceLive:
            "Microsoft MAI Live (preview)"
        case .maiTranscribe2:
            "Microsoft MAI-Transcribe-2"
        case .appleSpeechAnalyzer:
            "Apple SpeechAnalyzer"
        case .moonshineMediumStreaming:
            "Moonshine v2 Medium Streaming"
        case .parakeetStreaming:
            "Parakeet"
        }
    }

    public var detail: String {
        switch self {
        case .maiVoiceLive:
            "Streaming via Voice Live; MAI version unconfirmed"
        case .maiTranscribe2:
            "Azure cloud; clean text after tapping Stop"
        case .appleSpeechAnalyzer:
            "System-managed, on-device baseline"
        case .moonshineMediumStreaming:
            "Open-weight streaming model; downloaded once"
        case .parakeetStreaming:
            "English on this iPhone; one-time 731 MB download"
        }
    }
}

public enum PostProcessorID: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case rules
    case foundationModels
    case foundationModelsStructured

    public var id: String { rawValue }

    public var usesLanguageModel: Bool { self == .foundationModels || self == .foundationModelsStructured }

    public var displayName: String {
        switch self {
        case .none:
            "Raw transcript"
        case .rules:
            "Fast local rules"
        case .foundationModels:
            "Faithful cleanup (Apple Intelligence)"
        case .foundationModelsStructured:
            "Paragraphs & bullets (Apple Intelligence)"
        }
    }
}

public enum SpeechEngineUpdate: Sendable {
    case preparing(message: String, progress: Double?)
    case partial(text: String, receivedAt: Date)
    case final(text: String, endOfUtteranceLatencyMilliseconds: Double?, receivedAt: Date)
    case failure(message: String)
}

public struct SpeechMetrics: Equatable, Sendable {
    public var firstPartialMilliseconds: Double?
    public var firstFinalMilliseconds: Double?
    public var latestEndOfUtteranceMilliseconds: Double?
    public var finalizedCharacterCount: Int

    public init(
        firstPartialMilliseconds: Double? = nil,
        firstFinalMilliseconds: Double? = nil,
        latestEndOfUtteranceMilliseconds: Double? = nil,
        finalizedCharacterCount: Int = 0
    ) {
        self.firstPartialMilliseconds = firstPartialMilliseconds
        self.firstFinalMilliseconds = firstFinalMilliseconds
        self.latestEndOfUtteranceMilliseconds = latestEndOfUtteranceMilliseconds
        self.finalizedCharacterCount = finalizedCharacterCount
    }
}
