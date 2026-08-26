import Foundation

/// Very short, extremely common utterances ("hello"/"yes"/"no"/"okay" and
/// their en/de/pl equivalents) that carry inherently weak signal — both
/// for language *identification* (measured directly against the real
/// `NLLanguageRecognizer`: "hello" scores only ~0.13 confidence for
/// English, its actual language; "no"/"goodbye" score even lower and get
/// assigned to entirely wrong languages) and, for the same underlying
/// reason, for Auto-mode session language-*locking* hysteresis (see
/// `AIConversationEngine.resolveSourceLanguage(for:)`).
///
/// One shared definition so `AppleLanguageTranslator` (detection) and
/// `AIConversationEngine` (lock hysteresis) always agree on exactly
/// which utterances are "ambiguous," rather than two independently
/// maintained lists silently drifting apart.
///
/// Deliberately a small, closed, exact-match set — NOT a general "is this
/// text short" heuristic. That distinction matters concretely: "Guten
/// Tag" is only two words, but it's a perfectly confident, unambiguous
/// detection (~0.97 confidence) that a locked session legitimately needs
/// to be able to switch to — a word-count-only heuristic would wrongly
/// suppress that switch. Only text that's actually IN this table is
/// "ambiguous" for hysteresis purposes.
enum CommonShortUtterances {
    static let byLanguage: [String: [String]] = [
        "en": ["hello", "hi", "hey", "yes", "yeah", "yep", "no", "nope", "thanks", "thank you", "okay", "ok", "goodbye", "bye"],
        "de": ["hallo", "ja", "nein", "danke", "tschüss", "auf wiedersehen"],
        "pl": ["cześć", "tak", "nie", "dziękuję", "dzięki", "do widzenia", "okej"],
    ]

    /// Flattened lookup: normalized word -> language. `byLanguage` is a
    /// `[String: [String]]` (hash-iteration order is randomized per
    /// process launch, by design) — the assertion below is what would
    /// catch a future word accidentally added under two languages before
    /// it ever becomes a non-deterministic bug (confirmed live once
    /// already: an earlier version of this table had "okay"/"ok" under
    /// both "en" and "de", and "okay" was intermittently detected as
    /// German depending on iteration order).
    static let languageByWord: [String: String] = {
        var map: [String: String] = [:]
        for (language, words) in byLanguage {
            for word in words {
                assert(
                    map[word] == nil,
                    "CommonShortUtterances has an ambiguous entry: \"\(word)\" appears under more than one language — remove the duplicate."
                )
                map[word] = language
            }
        }
        return map
    }()

    static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
    }

    /// The curated language for `text`, or `nil` if it isn't one of these
    /// specific known utterances.
    static func language(for text: String) -> String? {
        languageByWord[normalize(text)]
    }

    /// Whether `text` is one of these known-ambiguous utterances — the
    /// signal `AIConversationEngine` uses to decide "too weak to switch
    /// an already-locked Auto session's language."
    static func isAmbiguous(_ text: String) -> Bool {
        languageByWord[normalize(text)] != nil
    }
}
