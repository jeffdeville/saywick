import Foundation

/// Local vocabulary correction. Explicit aliases take priority; standalone terms
/// use conservative spelling/sound matching without cascading replacements.
public struct CustomVocabulary: Sendable {
    public struct Entry: Sendable {
        public let heard: String
        public let preferred: String
        public let isExplicit: Bool
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
            parsed.append(Entry(heard: heard, preferred: parts.last!, isExplicit: parts.count == 2))
        }
        entries = parsed.sorted { $0.heard.count > $1.heard.count }
    }

    public var preferredWords: [String] { Array(Set(entries.map(\.preferred))).sorted() }

    private func correctSimilarTerms(in source: String) -> String {
        let terms = entries.filter { !$0.isExplicit && Self.normalized($0.preferred).count >= 4 }
        guard !terms.isEmpty else { return source }
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)?"#)
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < matches.count {
            var found: (Int, NSRange, String)?
            for count in stride(from: min(3, matches.count - index), through: 1, by: -1) {
                let range = NSUnionRange(matches[index].range, matches[index + count - 1].range)
                let heard = ns.substring(with: range)
                // Never join words across punctuation or sentence boundaries.
                guard heard.allSatisfy({ $0.isLetter || $0.isWhitespace }) else { continue }
                let normalized = Self.normalized(heard)
                guard !["may", "will", "bill", "mark", "rose", "faith", "hope", "grace", "chase", "summer", "april", "june"].contains(normalized) else { continue }
                guard normalized.count >= 4 else { continue }
                // Explicit corrections own their input, even when a fuzzy candidate exists.
                guard !entries.contains(where: { $0.isExplicit && $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) else { continue }
                let candidates = terms.compactMap { term -> (String, Int)? in
                    guard !entries.contains(where: { $0.isExplicit && $0.heard.caseInsensitiveCompare(term.preferred) == .orderedSame }) else { return nil }
                    let target = Self.normalized(term.preferred)
                    guard target.first == normalized.first else { return nil }
                    let distance = Self.distance(normalized, target)
                    let close = distance <= (target.count >= 6 ? 2 : 1)
                    let soundsClose = Self.soundKey(normalized) == Self.soundKey(target)
                    guard distance == 0 || (close && (soundsClose || target.count >= 7)) else { return nil }
                    return (term.preferred, distance)
                }.sorted { $0.1 < $1.1 }
                guard let best = candidates.first,
                      best.1 == 0 || candidates.count == 1 || candidates[1].1 - best.1 >= 2 else { continue }
                found = (count, range, best.0)
                break
            }
            if let (count, range, word) = found {
                replacements.append((range, word)); index += count
            } else { index += 1 }
        }
        var result = source
        for (range, word) in replacements.reversed() {
            if let range = Range(range, in: result) { result.replaceSubrange(range, with: word) }
        }
        return result
    }

    private static func normalized(_ word: String) -> String {
        String(word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter(\.isLetter))
    }
    private static func soundKey(_ word: String) -> String {
        let value = word.replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k").replacingOccurrences(of: "c", with: "k")
        var result = ""
        for letter in value where !"aeiouy".contains(letter) {
            if result.last != letter { result.append(letter) }
        }
        return result
    }
    private static func distance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1]
            for (j, y) in b.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1)))
            }
            row = next
        }
        return row[b.count]
    }

    public func apply(to source: String) -> String {
        let source = correctSimilarTerms(in: source)
        guard !entries.isEmpty else { return source }
        let protectedWords: Set<String> = ["may", "will", "bill", "mark", "rose", "faith", "hope", "grace", "chase", "summer", "april", "june"]
        let entries = entries.filter { $0.isExplicit || !protectedWords.contains($0.heard.lowercased()) }
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
