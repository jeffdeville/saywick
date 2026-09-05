import Foundation

public enum SharedSessionPhase: String, Codable, Sendable {
    case idle
    case preparing
    case listening
    case finalizing
    case ready
    case failed
}

public struct SharedSessionSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var revision: Int
    public var phase: SharedSessionPhase
    public var engineID: SpeechEngineID
    public var finalizedText: String
    public var partialText: String
    public var processedText: String
    public var message: String
    public var shouldAutoInsert: Bool
    public var updatedAt: Date

    public init(
        sessionID: UUID = UUID(),
        revision: Int = 0,
        phase: SharedSessionPhase = .idle,
        engineID: SpeechEngineID = .moonshineMediumStreaming,
        finalizedText: String = "",
        partialText: String = "",
        processedText: String = "",
        message: String = "",
        shouldAutoInsert: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.phase = phase
        self.engineID = engineID
        self.finalizedText = finalizedText
        self.partialText = partialText
        self.processedText = processedText
        self.message = message
        self.shouldAutoInsert = shouldAutoInsert
        self.updatedAt = updatedAt
    }

    public var liveText: String {
        [finalizedText, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var insertableText: String {
        processedText.isEmpty ? finalizedText : processedText
    }
}

public enum VoiceCommandKind: String, Codable, Sendable {
    case stop
    case stopAndInsert
    case restart
    case clear
}

public struct SpokenVoiceCommandMatch: Equatable, Sendable {
    public var command: VoiceCommandKind
    public var transcriptBeforeCommand: String

    public init(command: VoiceCommandKind, transcriptBeforeCommand: String) {
        self.command = command
        self.transcriptBeforeCommand = transcriptBeforeCommand
    }
}

/// Recognizes deliberate commands at the end of a finalized utterance.
/// `clear` is intentionally accepted only as a standalone utterance to avoid
/// treating ordinary dictated uses of that word as a destructive command.
public enum SpokenVoiceCommandParser {
    public static func match(in source: String) -> SpokenVoiceCommandMatch? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let commands: [(phrase: String, kind: VoiceCommandKind, standalone: Bool)] = [
            ("stop and insert", .stopAndInsert, false),
            ("stop and restart", .restart, false),
            ("clear transcript", .clear, true),
            ("clear", .clear, true),
        ]

        for candidate in commands {
            guard let range = text.range(
                of: candidate.phrase,
                options: [.caseInsensitive, .backwards]
            ) else { continue }

            let suffix = text[range.upperBound...]
            guard containsOnlyCommandPadding(suffix) else { continue }

            let prefix = text[..<range.lowerBound]
            guard prefix.isEmpty || isWordBoundary(prefix.last) else { continue }
            if candidate.standalone, !containsOnlyCommandPadding(prefix) {
                continue
            }

            return SpokenVoiceCommandMatch(
                command: candidate.kind,
                transcriptBeforeCommand: candidate.standalone
                    ? ""
                    : trimCommandSeparator(from: String(prefix))
            )
        }

        return nil
    }

    private static func containsOnlyCommandPadding(_ text: Substring) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func isWordBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func trimCommandSeparator(from source: String) -> String {
        var result = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, ",;:-\u{2014}".contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

public struct VoiceCommand: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: VoiceCommandKind
    public var issuedAt: Date

    public init(id: UUID = UUID(), kind: VoiceCommandKind, issuedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.issuedAt = issuedAt
    }
}
