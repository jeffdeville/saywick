import Foundation

/// Local, explicit spelling corrections. No fuzzy matching or cascading rewrites.
public struct CustomVocabulary: Sendable {
    public struct Entry: Sendable {
        public let heard: String
        public let preferred: String
    }
    public let entries: [Entry]

    public enum ValidationError: LocalizedError {
        case invalidLine(Int)
        case duplicate(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidLine(let line): "Line \(line): use a word, or heard spelling = preferred spelling."
            case .duplicate(let line): "Line \(line): that heard spelling already has an entry."
            }
        }
    }

    public init(_ source: String) throws {
        var parsed: [Entry] = []
        var seen: Set<String> = []
        for (offset, line) in source.components(separatedBy: .newlines).enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let parts = text.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty }) else {
                throw ValidationError.invalidLine(offset + 1)
            }
            let heard = parts[0]
            guard seen.insert(heard.lowercased()).inserted else { throw ValidationError.duplicate(offset + 1) }
            parsed.append(Entry(heard: heard, preferred: parts.last!))
        }
        entries = parsed.sorted { $0.heard.count > $1.heard.count }
    }

    public var preferredWords: [String] { Array(Set(entries.map(\.preferred))).sorted() }

    public func apply(to source: String) -> String {
        guard !entries.isEmpty else { return source }
        let alternatives = entries.map { "(" + NSRegularExpression.escapedPattern(for: $0.heard) + ")" }
            .joined(separator: "|")
        // Unicode letters, combining marks, digits, and underscores are word
        // characters. Apostrophes remain boundaries, preserving possessives.
        let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{M}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return source }
        let original = source as NSString
        var result = source
        // Matches are computed on the original only, so replacements never cascade.
        for match in regex.matches(in: source, range: NSRange(location: 0, length: original.length)).reversed() {
            guard let index = entries.indices.first(where: { match.range(at: $0 + 1).location != NSNotFound }),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: entries[index].preferred)
        }
        return result
    }
}
