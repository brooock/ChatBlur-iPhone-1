import Foundation

/// Normalises text so that OCR output and user keywords can be compared robustly:
/// case-insensitive, accent/umlaut-insensitive, punctuation and repeated spaces ignored.
enum TextNormalizer {
    static func normalize(_ input: String) -> String {
        let folded = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        return scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func tokens(_ input: String) -> [String] {
        normalize(input).split(separator: " ").map(String.init)
    }
}

struct KeywordMatch: Sendable {
    /// The keyword exactly as the user typed it.
    let keyword: String
    /// True when the match was only found with OCR error tolerance (e.g. "Danlel" for "Daniel").
    let isFuzzy: Bool
}

/// Matching rules (documented in README):
/// * Default: whole-word / whole-phrase search ("Anna" matches "Hallo Anna!" but not "Annalena").
/// * Optional: partial-word search ("Anna" also matches "Annalena").
/// * Optional (default on): tolerate one OCR error for keywords with ≥ 5 letters, two for ≥ 10 letters.
/// * Number-like keywords (e.g. phone numbers) are compared digit-by-digit, ignoring spaces, "+", "-", "/".
struct KeywordMatcher: Sendable {
    private struct Pattern: Sendable {
        let original: String
        let tokens: [String]
        let phrase: String
        let compact: String
        let digits: String?
    }

    private let patterns: [Pattern]
    private let allowPartialWords: Bool
    private let tolerateOCRErrors: Bool

    var isEmpty: Bool { patterns.isEmpty }

    init(keywords: [String], allowPartialWords: Bool, tolerateOCRErrors: Bool) {
        self.allowPartialWords = allowPartialWords
        self.tolerateOCRErrors = tolerateOCRErrors
        var seen = Set<String>()
        var result: [Pattern] = []
        for raw in keywords {
            let tokens = TextNormalizer.tokens(raw)
            guard !tokens.isEmpty else { continue }
            let phrase = tokens.joined(separator: " ")
            guard seen.insert(phrase).inserted else { continue }

            let digits = raw.filter { $0.isASCII && $0.isNumber }
            let hasLetters = raw.contains { $0.isLetter }
            var digitPattern: String?
            if !hasLetters && digits.count >= 4 {
                // Ignore leading zeros so "0176 123" also matches "+49 176 123".
                let core = String(digits.drop(while: { $0 == "0" }))
                digitPattern = core.count >= 4 ? core : digits
            }
            result.append(Pattern(
                original: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: tokens,
                phrase: phrase,
                compact: tokens.joined(),
                digits: digitPattern
            ))
        }
        patterns = result
    }

    func match(_ text: String) -> KeywordMatch? {
        let lineTokens = TextNormalizer.tokens(text)
        guard !lineTokens.isEmpty else { return nil }
        let line = lineTokens.joined(separator: " ")
        let lineDigits = text.filter { $0.isASCII && $0.isNumber }

        for pattern in patterns {
            if let digits = pattern.digits {
                if lineDigits.contains(digits) {
                    return KeywordMatch(keyword: pattern.original, isFuzzy: false)
                }
                continue
            }
            if Self.containsSequence(lineTokens, pattern.tokens) {
                return KeywordMatch(keyword: pattern.original, isFuzzy: false)
            }
            if allowPartialWords && line.contains(pattern.phrase) {
                return KeywordMatch(keyword: pattern.original, isFuzzy: false)
            }
            if tolerateOCRErrors && fuzzyMatch(lineTokens, pattern) {
                return KeywordMatch(keyword: pattern.original, isFuzzy: true)
            }
        }
        return nil
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var equal = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                equal = false
                break
            }
            if equal { return true }
        }
        return false
    }

    private func fuzzyMatch(_ lineTokens: [String], _ pattern: Pattern) -> Bool {
        let length = pattern.compact.count
        let allowed = length >= 10 ? 2 : (length >= 5 ? 1 : 0)
        guard allowed > 0 else { return false }

        // OCR sometimes splits or merges words, so compare windows of n-1, n and n+1 tokens.
        let sizes = Set([pattern.tokens.count - 1, pattern.tokens.count, pattern.tokens.count + 1]).filter { $0 >= 1 }
        for size in sizes where size <= lineTokens.count {
            for start in 0...(lineTokens.count - size) {
                let candidate = lineTokens[start..<(start + size)].joined()
                if allowPartialWords && candidate.count > length {
                    if Self.bestSubstringDistance(pattern: pattern.compact, in: candidate, limit: allowed) <= allowed {
                        return true
                    }
                } else if abs(candidate.count - length) <= allowed,
                          Self.levenshtein(Array(candidate), Array(pattern.compact), limit: allowed) <= allowed {
                    return true
                }
            }
        }
        return false
    }

    /// Edit distance with early exit once every value in a row exceeds `limit`.
    private static func levenshtein(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Smallest edit distance between `pattern` and any substring of `text` (approximate substring search).
    private static func bestSubstringDistance(pattern: String, in text: String, limit: Int) -> Int {
        let p = Array(pattern)
        let t = Array(text)
        guard !p.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: t.count + 1)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...p.count {
            current[0] = i
            if !t.isEmpty {
                for j in 1...t.count {
                    let cost = p[i - 1] == t[j - 1] ? 0 : 1
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                }
            }
            swap(&previous, &current)
        }
        return min(previous.min() ?? limit + 1, limit + 1)
    }
}
