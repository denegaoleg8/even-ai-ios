import Foundation

/// Maintains `PersonalAIStyleProfile`. Two very different inputs:
///
/// - **Explicit directives** ("keep replies short", "use Ukrainian with me",
///   "never open with 'thanks for sharing'") — applied immediately at full
///   weight, `source == .explicitCommand`, and they win over any inferred
///   value.
/// - **Inferred signals** from ordinary messages (length, formality markers)
///   — accumulated, and only allowed to move a projected dimension after
///   `StyleDimensionMeta.inferredObservationThreshold` corroborating
///   observations. One terse message never permanently makes the AI terse.
struct StyleProfileLearner: Sendable {

    init() {}

    // MARK: - Explicit directives

    /// Applies a natural-language style directive. Returns the updated
    /// profile; the caller persists it.
    func applyingDirective(_ directive: String, to profile: PersonalAIStyleProfile, now: Date = .now) -> PersonalAIStyleProfile {
        var p = profile
        let l = directive.lowercased()

        func set(_ key: String, _ apply: () -> Void) {
            apply()
            p.evidence[key] = StyleDimensionMeta(source: .explicitCommand, confidence: 0.95, observationCount: 99, updatedAt: now)
        }

        if l.contains("short") || l.contains("brief") || l.contains("concise") || l.contains("terse")
            || l.contains("коротк") || l.contains("стисл") || l.contains("лаконічн") {
            set("responseLength") { p.responseLength = .short }
        }
        if l.contains("detailed") || l.contains("thorough") || l.contains("in depth") || l.contains("long")
            || l.contains("детальн") || l.contains("докладн") || l.contains("розгорнут") {
            set("responseLength") { p.responseLength = .long }
        }
        if l.contains("direct") || l.contains("blunt") || l.contains("straight") || l.contains("no fluff")
            || l.contains("прямо") || l.contains("без води") || l.contains("по суті") {
            set("directness") { p.directness = 0.9 }
        }
        if l.contains("gentle") || l.contains("soft") || l.contains("diplomatic") {
            set("directness") { p.directness = 0.25 }
        }
        if l.contains("formal") && !l.contains("less formal") && !l.contains("informal") {
            set("formality") { p.formality = 0.85 }
        }
        if l.contains("less formal") || l.contains("informal") || l.contains("casual") {
            set("formality") { p.formality = 0.2 }
        }
        if l.contains("technical") || l.contains("code-level") || l.contains("deep dive") {
            set("technicalDepth") { p.technicalDepth = 0.85 }
        }
        if l.contains("proactive") || l.contains("suggest next") || l.contains("tell me what to do") {
            set("proactiveness") { p.proactiveness = 0.85 }
        }
        if l.contains("no bullet") || l.contains("don't use bullet") || l.contains("prose") || l.contains("paragraph") {
            set("formatting") { p.formatting = .prose }
        }
        if (l.contains("bullet") || l.contains("list")) && !l.contains("no bullet") && !l.contains("don't use bullet") {
            set("formatting") { p.formatting = .bullets }
        }

        // Language: "use Ukrainian", "reply in English", "speak to me in German".
        if let lang = Self.detectLanguageDirective(l) {
            set("preferredLanguage") { p.preferredLanguage = lang }
        }

        // Phrases to avoid: "avoid the phrase X", "never say 'X'", "don't open with 'X'".
        if let phrase = Self.extractQuotedOrTrailing(after: ["avoid the phrase", "avoid saying", "never say", "stop saying", "don't say", "dont say", "don't open with", "don't use the phrase"], in: directive) {
            if !p.phrasesToAvoid.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
                p.phrasesToAvoid.append(phrase)
            }
            p.evidence["phrasesToAvoid"] = StyleDimensionMeta(source: .explicitCommand, confidence: 0.95, observationCount: 99, updatedAt: now)
        }

        p.updatedAt = now
        return p
    }

    // MARK: - Inferred signals

    /// Folds one ordinary user message into the profile's inferred evidence.
    /// Only mutates a *projected* dimension once its observation count
    /// crosses the threshold — before that it just accumulates.
    func observing(userMessage text: String, in profile: PersonalAIStyleProfile, now: Date = .now) -> PersonalAIStyleProfile {
        var p = profile
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count

        // Signal: very short messages ⇒ user likes brevity (weak).
        let brevitySignal: Double = words <= 6 ? 1.0 : (words >= 40 ? -1.0 : 0.0)
        if brevitySignal != 0, let meta = bumpedMeta(&p, key: "responseLength", now: now),
           meta.observationCount >= StyleDimensionMeta.inferredObservationThreshold {
            p.responseLength = brevitySignal > 0 ? .short : .long
        }

        // Signal: politeness / formality markers.
        let formalMarkers = ["could you", "would you", "please kindly", "i would appreciate", "kind regards"]
        let casualMarkers = ["yeah", "yep", "nah", "gonna", "wanna", "lol", "thx", "cool"]
        let l = text.lowercased()
        if formalMarkers.contains(where: l.contains), let meta = bumpedMeta(&p, key: "formality", now: now),
           meta.observationCount >= StyleDimensionMeta.inferredObservationThreshold {
            p.formality = 0.7
        } else if casualMarkers.contains(where: l.contains), let meta = bumpedMeta(&p, key: "formality", now: now),
                  meta.observationCount >= StyleDimensionMeta.inferredObservationThreshold {
            p.formality = 0.3
        }

        p.updatedAt = now
        return p
    }

    /// Increments the inferred observation count for `key` and returns the
    /// updated meta — or `nil` if the dimension is explicitly set (in which
    /// case inferred signals must not touch it). No overlapping access:
    /// this only reads/writes `p.evidence`, the caller mutates the
    /// projected dimension afterwards.
    private func bumpedMeta(_ p: inout PersonalAIStyleProfile, key: String, now: Date) -> StyleDimensionMeta? {
        var meta = p.evidence[key] ?? StyleDimensionMeta(source: .inferredFromConversation, confidence: 0.3, observationCount: 0, updatedAt: now)
        guard meta.source != .explicitCommand, meta.source != .manualEntry else { return nil }
        meta.observationCount += 1
        meta.confidence = min(0.85, 0.3 + 0.1 * Double(meta.observationCount))
        meta.updatedAt = now
        meta.source = .inferredFromConversation
        p.evidence[key] = meta
        return meta
    }

    // MARK: - Static helpers

    static func detectLanguageDirective(_ lower: String) -> String? {
        let map: [(String, String)] = [
            ("ukrainian", "uk"), ("українськ", "uk"),
            ("english", "en"), ("англійськ", "en"),
            ("german", "de"), ("polish", "pl"), ("spanish", "es"),
            ("french", "fr"), ("italian", "it"),
        ]
        let triggers = ["use ", "speak ", "reply in ", "respond in ", "answer in ", "write in ", "talk to me in ", "speak to me in ",
                        "відповідай ", "пиши ", "спілкуйся ", "розмовляй "]
        guard triggers.contains(where: lower.contains) else { return nil }
        for (name, code) in map where lower.contains(name) { return code }
        return nil
    }

    static func extractQuotedOrTrailing(after triggers: [String], in text: String) -> String? {
        let l = text.lowercased()
        guard let trigger = triggers.first(where: { l.contains($0) }) else { return nil }
        guard let range = l.range(of: trigger) else { return nil }
        let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Prefer a quoted phrase.
        if let q = tail.firstMatch(of: /["'“”‘’](.+?)["'“”‘’]/) {
            return String(q.1).trimmingCharacters(in: .whitespaces)
        }
        let cleaned = tail.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:\"'"))
        return cleaned.isEmpty ? nil : cleaned
    }
}
