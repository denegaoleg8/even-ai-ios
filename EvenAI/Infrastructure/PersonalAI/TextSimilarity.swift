import Foundation

/// Lexical text utilities for Phase 1 retrieval and merge. Deliberately
/// simple and fully deterministic — tokenise, drop stopwords, light suffix
/// stem, then Jaccard / overlap scoring. This is the seam where a Phase 2
/// on-device embedding model would slot in (`semanticSimilarity` would call
/// it; every caller stays the same).
enum TextSimilarity {
    /// Very small English/Ukrainian stopword set — enough to stop "the",
    /// "is", "I", "я", "це" from dominating overlap scores.
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "of", "to", "in",
        "on", "at", "for", "with", "is", "are", "was", "were", "be", "been",
        "am", "i", "you", "he", "she", "it", "we", "they", "my", "your", "our",
        "me", "us", "this", "that", "these", "those", "as", "so", "do", "did",
        "does", "have", "has", "had", "not", "no", "yes", "can", "will", "just",
        "about", "from", "by", "up", "out", "please", "im", "ive",
        "я", "ти", "він", "вона", "воно", "ми", "ви", "вони", "це", "той",
        "та", "і", "й", "в", "на", "з", "до", "що", "як", "бо", "але", "не",
    ]

    /// Lowercased, punctuation-stripped, stopword-filtered, lightly stemmed
    /// tokens. Order not preserved; duplicates preserved (callers that want
    /// a set can `Set(...)`).
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .filter { !stopwords.contains($0) }
            .map(stem)
            .filter { $0.count > 1 }
    }

    static func tokenSet(_ text: String) -> Set<String> {
        Set(tokens(text))
    }

    /// Crude suffix stripping — collapses "problems"/"problem",
    /// "building"/"build", "replies"/"reply". Only touches ASCII words so
    /// Ukrainian tokens pass through unchanged.
    static func stem(_ word: String) -> String {
        guard word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return word }
        var w = word
        for suffix in ["ies"] where w.hasSuffix(suffix) && w.count > suffix.count + 1 {
            return String(w.dropLast(suffix.count)) + "y"
        }
        for suffix in ["ing", "edly", "ed", "es", "ly", "s"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            w = String(w.dropLast(suffix.count))
            break
        }
        return w
    }

    /// Jaccard similarity of the two token sets, 0…1.
    static func jaccard(_ a: String, _ b: String) -> Double {
        let sa = tokenSet(a), sb = tokenSet(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        let inter = Double(sa.intersection(sb).count)
        let union = Double(sa.union(sb).count)
        return union == 0 ? 0 : inter / union
    }

    /// Fraction of `needle`'s tokens present in `haystack` (asymmetric) —
    /// better than Jaccard when a short query is checked against a longer
    /// memory statement.
    static func coverage(needle: String, haystack: String) -> Double {
        let sn = tokenSet(needle)
        guard !sn.isEmpty else { return 0 }
        let sh = tokenSet(haystack)
        return Double(sn.intersection(sh).count) / Double(sn.count)
    }

    /// Best of the two directions of `coverage` plus a Jaccard floor — the
    /// general "how related are these two strings" number retrieval uses.
    static func semanticSimilarity(_ a: String, _ b: String) -> Double {
        let c1 = coverage(needle: a, haystack: b)
        let c2 = coverage(needle: b, haystack: a)
        return max(jaccard(a, b), 0.5 * (c1 + c2) * 0.9)
    }

    /// Whether two strings look like the *same fact stated twice* — high
    /// bidirectional coverage. Used by the merger's duplicate check.
    static func looksLikeDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalizedForComparison(a)
        let nb = normalizedForComparison(b)
        if na == nb { return true }
        return coverage(needle: a, haystack: b) >= 0.8 && coverage(needle: b, haystack: a) >= 0.8
    }

    static func normalizedForComparison(_ s: String) -> String {
        tokens(s).sorted().joined(separator: " ")
    }

    /// Shared entity/keyword tokens between two strings — the basis for
    /// "these talk about the same project/person".
    static func sharedEntities(_ a: String, _ b: [String]) -> [String] {
        let sa = tokenSet(a)
        return b.filter { entity in
            let se = tokenSet(entity)
            return !se.isEmpty && !se.isDisjoint(with: sa)
        }
    }
}
