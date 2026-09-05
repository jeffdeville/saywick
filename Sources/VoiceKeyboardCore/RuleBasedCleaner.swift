import Foundation

public enum RuleBasedCleaner {
    public static func clean(_ source: String) -> String {
        var text = source
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return "" }

        if let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }

        if let last = text.last, !".!?…".contains(last) {
            text.append(".")
        }

        return text
    }
}

/// Removes presentation wrappers that a language model may add despite being
/// asked for plain text. Only wrappers around the entire response are removed.
public enum TranscriptOutputSanitizer {
    public static func clean(_ source: String) -> String {
        var result = source.trimmingCharacters(in: .whitespacesAndNewlines)

        // A response can contain nested wrappers, such as a Markdown fence
        // around an XML transcript block, so unwrap a few times if necessary.
        for _ in 0..<3 {
            let previous = result
            result = stripMarkdownFence(from: result)
            result = stripTranscriptTag(from: result)
            result = stripTranscriptLabel(from: result)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if result == previous { break }
        }

        return result
    }

    private static func stripMarkdownFence(from source: String) -> String {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else {
            return source
        }

        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func stripTranscriptTag(from source: String) -> String {
        for tag in ["transcript", "cleaned-transcript", "cleaned_transcript"] {
            let opening = "<\(tag)>"
            let closing = "</\(tag)>"
            guard source.lowercased().hasPrefix(opening),
                  source.lowercased().hasSuffix(closing) else { continue }

            let start = source.index(source.startIndex, offsetBy: opening.count)
            let end = source.index(source.endIndex, offsetBy: -closing.count)
            return String(source[start..<end])
        }
        return source
    }

    private static func stripTranscriptLabel(from source: String) -> String {
        for label in ["cleaned transcript:", "transcript:", "cleaned text:"] {
            guard source.lowercased().hasPrefix(label) else { continue }
            let start = source.index(source.startIndex, offsetBy: label.count)
            return String(source[start...])
        }
        return source
    }
}
