import Foundation

/// Disjoint edit targets with read-only overlap. Context is never appended to output.
public struct TranscriptCleanupChunk: Sendable, Equatable {
    public let before: String
    public let text: String
    public let after: String
}

public enum TranscriptCleanup {
    public static let targetByteLimit = 1200
    public static let contextByteLimit = 240

    public static func chunks(_ text: String) -> [TranscriptCleanupChunk] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var ranges: [Range<Int>] = []
        var start = 0
        var size = 0
        for index in words.indices {
            let next = words[index].utf8.count + (index == start ? 0 : 1)
            if size + next > targetByteLimit, index > start {
                // Prefer a nearby punctuation boundary to avoid inviting the
                // model to complete a cut-off phrase from read-only context.
                // It is only a processing boundary, not a trusted sentence end.
                let boundary = words[start..<index].lastIndex {
                    $0.last.map { ".!?…".contains($0) } ?? false
                }.map { $0 + 1 } ?? index
                ranges.append(start..<boundary)
                start = boundary
                size = words[start..<index].joined(separator: " ").utf8.count
            }
            size += words[index].utf8.count + (index == start ? 0 : 1)
        }
        if start < words.count { ranges.append(start..<words.count) }
        return ranges.map { range in
            var left = range.lowerBound
            var right = range.upperBound
            var bytes = 0
            while left > 0, bytes + words[left - 1].utf8.count + 1 <= contextByteLimit {
                left -= 1
                bytes += words[left].utf8.count + 1
            }
            bytes = 0
            while right < words.count, bytes + words[right].utf8.count + 1 <= contextByteLimit {
                bytes += words[right].utf8.count + 1
                right += 1
            }
            return TranscriptCleanupChunk(before: words[left..<range.lowerBound].joined(separator: " "),
                text: words[range].joined(separator: " "),
                after: words[range.upperBound..<right].joined(separator: " "))
        }
    }

    public static func instructions(structured: Bool) -> String {
        """
        Repair speech-recognition fragments into grammatical English sentences. Thinking pauses often produce false periods and capitals inside a sentence: remove those periods and fix sentence case. Use grammar and surrounding context to decide where sentences actually end.
        Examples:
        "We need to. Call Sam tomorrow." -> "We need to call Sam tomorrow."
        "I was wondering. If the API is ready." -> "I was wondering if the API is ready."
        "Call Sam. Then email Breccan." -> "Call Sam. Then email Breccan."
        Preserve every word in order, including fillers, repetitions, names, numbers and acronyms. Change only punctuation, case and whitespace. Do not summarize, paraphrase or answer the transcript.
        \(structured ? "Use paragraphs and unnumbered bullets for clear lists or topic changes. Do not invent headings or reorder words." : "Return plain prose without bullets, headings or lists.")
        Before and after are read-only context. Return only the corrected target. Do not force sentence boundaries at target edges. Never copy context, instructions, labels or delimiters into the answer.
        """
    }

    public static func prompt(_ chunk: TranscriptCleanupChunk, preference: String, preferredWords: [String]) -> String {
        """
        Formatting preference (only within the word-preservation rules): \(preference)
        Preferred spellings (do not substitute words): \(preferredWords.joined(separator: ", "))
        Before (context only): \(chunk.before)
        After (context only): \(chunk.after)

        Edit ONLY the following target. Exclude all before/after context from the response:
        \(chunk.text)
        """
    }

    /// Reject omissions, additions, reordered words and changes to numbers,
    /// contractions or acronyms. Sentence case and punctuation may change.
    public static func preservesWords(source: String, candidate: String) -> Bool {
        let original = tokens(source)
        let edited = tokens(candidate)
        guard original.map({ $0.lowercased() }) == edited.map({ $0.lowercased() }) else { return false }
        for (before, after) in zip(original, edited) {
            let letters = before.filter(\.isLetter)
            if letters.count > 1, letters == letters.uppercased(), before != after { return false }
        }
        let protectedSymbols: (String) -> String = { text in
            String(text.unicodeScalars.filter {
                CharacterSet.symbols.contains($0) || "%#@\\".unicodeScalars.contains($0)
            })
        }
        return protectedSymbols(source) == protectedSymbols(candidate)
    }

    public static func hasListMarkup(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*(?:[-*•]\s|#{1,6}\s|[0-9]+[.)]\s)"#,
                   options: .regularExpression) != nil
    }

    private static func tokens(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        let pattern = #"(?:-(?=\p{N}))?[\p{L}\p{M}\p{N}]+(?:['._:/@+\-][\p{L}\p{M}\p{N}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = normalized as NSString
        return regex.matches(in: normalized, range: NSRange(location: 0, length: string.length))
            .map { string.substring(with: $0.range) }
    }
}
