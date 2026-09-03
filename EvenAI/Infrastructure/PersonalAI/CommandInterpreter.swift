import Foundation

/// Detects memory-affecting intent in a user message *without* requiring
/// slash commands or exact wording — "remember that…", "keep in mind…",
/// "from now on…", "always…", "never…", "forget about…", "stop
/// remembering…", plus common style directives ("keep replies short", "use
/// Ukrainian with me"). Deterministic and fully testable; a future LLM
/// extractor can supersede it but the same `MemoryCommand` output shape
/// stays.
struct CommandInterpreter: Sendable {

    /// Trigger → how to interpret the remainder. Checked longest-first so
    /// "don't forget" wins over "don't".
    private enum Kind { case remember, rule, forget, style }

    private static let triggers: [(phrase: String, kind: Kind)] = {
        let raw: [(String, Kind)] = [
            // remember
            ("remember that ", .remember),
            ("remember to ", .remember),
            ("remember ", .remember),
            ("keep in mind that ", .remember),
            ("keep in mind ", .remember),
            ("note that ", .remember),
            ("make a note that ", .remember),
            ("make a note ", .remember),
            ("for the record ", .remember),
            ("don't forget that ", .remember),
            ("don't forget ", .remember),
            ("dont forget ", .remember),
            ("fyi ", .remember),
            // remember — Ukrainian ("запам'ятай …", also the colon form
            // "запам'ятай: …"; the three apostrophe encodings are folded to
            // U+0027 by `normalize`, and a comma / colon after the trigger is
            // handled by `consumedLength` before the remainder is taken).
            ("запам'ятай що ", .remember),
            ("запам'ятай ", .remember),
            ("запам'ятайте ", .remember),
            ("зауваж що ", .remember),
            ("на замітку ", .remember),
            // forget
            ("forget about ", .forget),
            ("forget that ", .forget),
            ("forget the ", .forget),
            ("forget ", .forget),
            ("stop remembering ", .forget),
            ("you can forget ", .forget),
            ("delete the memory about ", .forget),
            ("delete the memory ", .forget),
            ("remove the memory about ", .forget),
            ("remove the memory ", .forget),
            ("erase the memory ", .forget),
            // forget — Ukrainian ("забудь про …", "забудь …").
            ("забудь про ", .forget),
            ("забудьте про ", .forget),
            ("забудь що ", .forget),
            ("забудь ", .forget),
            ("забудьте ", .forget),
            // style (checked before generic rules)
            ("keep replies ", .style),
            ("keep your replies ", .style),
            ("keep business replies ", .style),
            ("keep answers ", .style),
            ("keep it short", .style),
            ("keep it brief", .style),
            ("keep it concise", .style),
            ("be concise", .style),
            ("be brief", .style),
            ("be more direct", .style),
            ("be direct", .style),
            ("be less formal", .style),
            ("be more formal", .style),
            ("use ukrainian", .style),
            ("speak ukrainian", .style),
            // style — Ukrainian ("відповідай коротко", "відповідай українською").
            ("відповідай коротко", .style),
            ("відповідай стисло", .style),
            ("відповідай лаконічно", .style),
            ("пиши коротко", .style),
            ("будь лаконічним", .style),
            ("відповідай українською", .style),
            ("відповідай мені українською", .style),
            ("пиши українською", .style),
            ("speak to me in ", .style),
            ("talk to me in ", .style),
            ("reply in ", .style),
            ("respond in ", .style),
            ("answer in ", .style),
            ("write in ", .style),
            ("avoid the phrase ", .style),
            ("avoid saying ", .style),
            ("don't say ", .style),
            ("dont say ", .style),
            ("stop saying ", .style),
            ("don't use the phrase ", .style),
            ("don't open with ", .style),
            ("no bullet points", .style),
            ("don't use bullet", .style),
            ("use bullet points", .style),
            // rule (generic, last)
            ("from now on ", .rule),
            ("going forward ", .rule),
            ("in the future ", .rule),
            ("in future ", .rule),
            ("always ", .rule),
            ("never ", .rule),
            ("whenever ", .rule),
            ("if i ask ", .rule),
            ("when i ask ", .rule),
            ("don't ever ", .rule),
            ("do not ever ", .rule),
            ("don't ", .rule),
            ("do not ", .rule),
            ("stop ", .rule),
            // rule — Ukrainian ("завжди …", "ніколи …").
            ("завжди ", .rule),
            ("ніколи ", .rule),
            ("відтепер ", .rule),
            ("надалі ", .rule),
            ("з цього моменту ", .rule),
        ]
        return raw.sorted { $0.0.count > $1.0.count }
    }()

    private static let leadingFillers = ["please ", "hey ", "ok ", "okay ", "so ", "also ", "and ", "btw ", "just ",
                                         "будь ласка ", "будь-ласка "]

    init() {}

    /// Single place where surface variation is folded out before any trigger
    /// matching or clause extraction happens — case is handled separately by
    /// `lowercased()`. Every substitution replaces one character with one
    /// character, so string offsets stay valid against the original.
    ///
    /// - The three apostrophe encodings a Ukrainian keyboard can produce —
    ///   U+2019 (’), U+02BC (ʼ) and U+0027 (') — collapse to a single ASCII
    ///   apostrophe so one set of Cyrillic triggers ("запам'ятай …") matches
    ///   every variant.
    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
    }

    /// Interprets every sentence in `message`; returns all non-trivial
    /// commands (usually 0 or 1). Order is preserved.
    func interpret(_ message: String) -> [MemoryCommand] {
        sentences(in: message).compactMap { interpretSentence($0) }
    }

    // MARK: - Sentence handling

    private func sentences(in message: String) -> [String] {
        message
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func interpretSentence(_ sentence: String) -> MemoryCommand? {
        var lower = Self.normalize(sentence.lowercased()).trimmingCharacters(in: .whitespaces)
        var display = Self.normalize(sentence).trimmingCharacters(in: .whitespaces)
        for filler in Self.leadingFillers where lower.hasPrefix(filler) {
            lower = String(lower.dropFirst(filler.count))
            display = String(display.dropFirst(filler.count))
        }

        // Tolerate a comma OR a colon where the trigger expects a space
        // ("From now on, …", "Remember: …", "Запам'ятай: …" as well as the
        // plain space forms). `consumedLength` walks the un-collapsed string
        // to keep clause offsets exact.
        let matchLower = lower
            .replacingOccurrences(of: ", ", with: " ")
            .replacingOccurrences(of: ": ", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        for (phrase, kind) in Self.triggers where matchLower.hasPrefix(phrase) {
            // The real consumed length can differ from `phrase.count` when a
            // comma was collapsed — walk both strings in lockstep.
            let consumed = Self.consumedLength(of: phrase, in: lower)
            let remainderLower = String(lower.dropFirst(consumed)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let remainderDisplay = String(display.dropFirst(consumed)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))

            switch kind {
            case .remember:
                let content = cleanClause(remainderDisplay.isEmpty ? sentence : remainderDisplay)
                guard content.count >= 3 else { return nil }
                return .remember(content: content, suggestedCategory: Self.categorize(content))

            case .forget:
                let query = cleanClause(remainderDisplay)
                guard query.count >= 2 else { return nil }
                return .forget(query: query)

            case .rule:
                // "don't remember X" / "stop remembering X" are forgets, not rules.
                if remainderLower.hasPrefix("remember") || remainderLower.hasPrefix("keep remembering") {
                    let q = cleanClause(remainderDisplay
                        .replacingOccurrences(of: "remembering ", with: "")
                        .replacingOccurrences(of: "remember ", with: ""))
                    return q.count >= 2 ? .forget(query: q) : nil
                }
                // Re-fold the trigger word back in so the rule text is a
                // complete imperative sentence.
                let ruleText = normalizeRule(trigger: phrase, remainder: remainderDisplay, original: sentence)
                guard ruleText.count >= 4 else { return nil }
                return .addRule(text: ruleText, scope: .global)

            case .style:
                return .setStyle(directive: cleanClause(sentence))
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Length of the prefix of `text` that corresponds to `phrase`, treating
    /// a single "," or ":" (optionally followed by a space) in `text` as
    /// equivalent to the space in `phrase`. Assumes `phrase` (with ", " / ": "
    /// / ":" collapsed to " ") is already a confirmed prefix of the collapsed
    /// `text`.
    private static func consumedLength(of phrase: String, in text: String) -> Int {
        var ti = text.startIndex
        var pi = phrase.startIndex
        while pi < phrase.endIndex, ti < text.endIndex {
            if phrase[pi] == " ", text[ti] == "," || text[ti] == ":" {
                // Consume ", " / ": " / ":" for the single space in the phrase.
                ti = text.index(after: ti)
                if ti < text.endIndex, text[ti] == " " { ti = text.index(after: ti) }
                pi = phrase.index(after: pi)
                continue
            }
            if phrase[pi] != text[ti] { break }
            ti = text.index(after: ti)
            pi = phrase.index(after: pi)
        }
        return text.distance(from: text.startIndex, to: ti)
    }

    private func cleanClause(_ s: String) -> String {
        var out = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:\"'"))
        // Normalise a leading "that " left over from some phrasings.
        if out.lowercased().hasPrefix("that ") { out = String(out.dropFirst(5)) }
        return out
    }

    private func normalizeRule(trigger: String, remainder: String, original: String) -> String {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        let keepTriggerInline = ["always", "never", "don't", "do not", "don't ever", "do not ever", "stop",
                                 "завжди", "ніколи"]
        let body: String
        if keepTriggerInline.contains(t) {
            body = "\(t.capitalizedFirst) \(remainder)"
        } else {
            // "from now on X" / "going forward X" → keep the whole sentence,
            // it already reads as an instruction.
            body = original.trimmingCharacters(in: .whitespaces)
        }
        return body
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
            .appendingPeriodIfNeeded()
    }

    /// Best-effort category for a "remember X" statement.
    static func categorize(_ content: String) -> MemoryCategory {
        let l = Self.normalize(content.lowercased())
        let profileMarkers = ["my name is", "i am ", "i'm ", "i live", "i'm based", "i was born", "my birthday", "i work as", "my job", "my role", "my email", "my phone", "my timezone", "i'm a ", "i am a ",
                              "мене звати", "мене звуть", "я живу", "я мешкаю", "я народив", "мій день народження", "я працюю", "моя посада", "моя робота", "мій часовий пояс", "мій email", "моя електронна", "мій телефон"]
        let prefMarkers = ["i prefer", "i like", "i love", "i hate", "i don't like", "i dislike", "i enjoy", "i'd rather", "i want you to", "my favorite", "my favourite",
                           "я віддаю перевагу", "я надаю перевагу", "мені подобається", "мені більше подобається", "я люблю", "я обожнюю", "я ненавиджу", "я не люблю", "мій улюблений", "моя улюблена", "моє улюблене", "я волію"]
        let projectMarkers = ["project", "building", "launch", "shipping", "deadline", "milestone", "roadmap", "sprint", "we're building", "i'm building", "working on", "the app", "release",
                              "проект", "проєкт", "я будую", "ми будуємо", "я створюю", "ми запускаємо", "запуск", "дедлайн", "реліз", "працюю над", "дорожня карта", "спринт", "віха"]
        let peopleMarkers = ["is my", "my co-founder", "my colleague", "my manager", "my boss", "my wife", "my husband", "my partner", "my friend", "my brother", "my sister", "reports to", "works with me",
                             "мій співзасновник", "моя співзасновниця", "мій колега", "моя колега", "мій менеджер", "мій керівник", "моя дружина", "мій чоловік", "мій партнер", "мій друг", "моя подруга", "мій брат", "моя сестра", "звітує переді мною"]
        if peopleMarkers.contains(where: l.contains) { return .people }
        if projectMarkers.contains(where: l.contains) { return .projects }
        if profileMarkers.contains(where: l.contains) { return .profile }
        if prefMarkers.contains(where: l.contains) { return .preferences }
        return .knowledge
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }

    func appendingPeriodIfNeeded() -> String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
