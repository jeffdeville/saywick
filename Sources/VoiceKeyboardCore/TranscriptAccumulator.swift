import Foundation

public struct TranscriptAccumulator: Equatable, Sendable {
    public private(set) var finalizedSegments: [String]
    public private(set) var partialText: String
    public private(set) var metrics: SpeechMetrics
    public private(set) var startedAt: Date

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.finalizedSegments = []
        self.partialText = ""
        self.metrics = SpeechMetrics()
    }

    public var finalizedText: String {
        finalizedSegments.joined(separator: " ")
    }

    public var currentText: String {
        [finalizedText, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public mutating func reset(at date: Date = Date()) {
        self = TranscriptAccumulator(startedAt: date)
    }

    public mutating func consume(_ update: SpeechEngineUpdate) {
        switch update {
        case .partial(let text, let receivedAt):
            let normalized = Self.normalize(text)
            partialText = normalized
            if !normalized.isEmpty, metrics.firstPartialMilliseconds == nil {
                metrics.firstPartialMilliseconds = elapsedMilliseconds(to: receivedAt)
            }

        case .final(let text, let latency, let receivedAt):
            let normalized = Self.normalize(text)
            if !normalized.isEmpty {
                finalizedSegments.append(normalized)
                if metrics.firstFinalMilliseconds == nil {
                    metrics.firstFinalMilliseconds = elapsedMilliseconds(to: receivedAt)
                }
            }
            partialText = ""
            metrics.latestEndOfUtteranceMilliseconds = latency
            metrics.finalizedCharacterCount = finalizedText.count

        case .preparing, .failure:
            break
        }
    }

    private func elapsedMilliseconds(to date: Date) -> Double {
        max(0, date.timeIntervalSince(startedAt) * 1_000)
    }

    private static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}
