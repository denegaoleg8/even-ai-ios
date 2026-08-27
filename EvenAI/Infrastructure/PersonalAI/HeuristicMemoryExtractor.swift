import Foundation

/// Phase 1 local `MemoryExtracting`: after a meaningful exchange, decide
/// whether anything durable was said. Deterministic — explicit "remember…"
/// commands plus a small set of durable self-fact / project / decision
/// patterns. Everything else is left alone.
///
/// **Never memorises:** filler / greetings, secrets (`SecretDetector`),
/// clearly temporary statements ("in Berlin this week" → `workingContext`
/// with an expiry, never `profile`), or unsupported inference (it only
/// records what the user actually said, not conclusions drawn from it).
struct HeuristicMemoryExtractor: MemoryExtracting {

    private let interpreter: CommandInterpreter

    init(interpreter: CommandInterpreter = CommandInterpreter()) {
        self.interpreter = interpreter
    }

    func extract(
        from exchange: PersonalAIExchange,
        existing: [MemoryRecord],
        excludedConversationIDs: Set<UUID>,
        memoryEnabled: Bool
    ) async -> [MemoryCandidate] {
        guard memoryEnabled else { return [] }
        guard !excludedConversationIDs.contains(exchange.conversationID) else { return [] }

        let text = exchange.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return [] }
        guard !SecretDetector.containsSecret(text) else { return [] }

        var candidates: [MemoryCandidate] = []
        let provenanceConversation = [exchange.conversationID]
        let provenanceMessage = exchange.userMessageID.map { [$0] } ?? []
        let commands = interpreter.interpret(text)

        // 1. Explicit "remember…" commands → high-trust candidates.
        for command in commands {
            guard case let .remember(content, category) = command else { continue }
            guard !SecretDetector.containsSecret(content) else { continue }
            let (finalCategory, expiresAt) = Self.applyTemporalHeuristics(content: content, category: category, now: exchange.timestamp)
            candidates.append(MemoryCandidate(
                record: MemoryRecord(
                    category: finalCategory,
                    scope: .global,
                    canonicalContent: Self.canonicalize(content),
                    entities: Self.entities(in: content),
                    createdAt: exchange.timestamp,
                    updatedAt: exchange.timestamp,
                    confidence: 0.9,
                    importance: 0.7,
                    userConfirmed: true,
                    expiresAt: expiresAt,
                    sourceConversationIDs: provenanceConversation,
                    sourceMessageIDs: provenanceMessage
                ),
                rationale: "explicit remember command",
                originatingCommand: command,
                salience: 0.95
            ))
        }

        // 2. Passive durable facts — only when the message is NOT itself a
        //    command. A "forget …" / "from now on …" / style directive is
        //    already fully handled by `MemoryCommandProcessor`; running
        //    passive capture on it too would re-store the command sentence
        //    as a fact (e.g. "forget that I prefer espresso" matches the
        //    "I prefer …" preference pattern).
        if commands.isEmpty, let passive = Self.durableFact(in: text) {
            let (finalCategory, expiresAt) = Self.applyTemporalHeuristics(content: passive.content, category: passive.category, now: exchange.timestamp)
            candidates.append(MemoryCandidate(
                record: MemoryRecord(
                    category: finalCategory,
                    scope: .global,
                    canonicalContent: Self.canonicalize(passive.content),
                    entities: Self.entities(in: passive.content),
                    createdAt: exchange.timestamp,
                    updatedAt: exchange.timestamp,
                    confidence: 0.6,
                    importance: passive.importance,
                    userConfirmed: false,
                    expiresAt: expiresAt,
                    sourceConversationIDs: provenanceConversation,
                    sourceMessageIDs: provenanceMessage
                ),
                rationale: passive.rationale,
                salience: 0.55
            ))
        }

        return candidates
    }

    // MARK: - Durable-fact patterns

    struct PassiveFact {
        var content: String
        var category: MemoryCategory
        var importance: Double
        var rationale: String
    }

    static func durableFact(in text: String) -> PassiveFact? {
        let l = text.lowercased()
        if Self.isFiller(l) { return nil }

        let projectMarkers = ["i'm building", "im building", "i am building", "we're building", "we are building",
                              "i'm working on", "im working on", "i am working on", "we're launching", "we are launching",
                              "the launch is", "we decided to", "i decided to", "we're shipping", "our goal is", "the deadline is"]
        if projectMarkers.contains(where: l.contains) {
            return PassiveFact(content: text, category: .projects, importance: 0.7, rationale: "durable project statement")
        }

        let profileMarkers = ["my name is", "i live in", "i'm based in", "im based in", "i am based in",
                              "i work as", "i'm a ", "im a ", "i am a ", "my role is", "my job is", "my timezone is"]
        if profileMarkers.contains(where: l.contains) {
            return PassiveFact(content: text, category: .profile, importance: 0.65, rationale: "durable self-fact")
        }

        let preferenceMarkers = ["i prefer ", "i always ", "i never ", "i can't stand ", "i hate ", "i love using ", "i'd rather "]
        if preferenceMarkers.contains(where: l.contains) {
            return PassiveFact(content: text, category: .preferences, importance: 0.5, rationale: "stated preference")
        }

        let peopleMarkers = [" is my co-founder", " is my colleague", " is my manager", " is my teammate", " reports to me", " is on my team"]
        if peopleMarkers.contains(where: l.contains) {
            return PassiveFact(content: text, category: .people, importance: 0.55, rationale: "person context")
        }

        return nil
    }

    static func isFiller(_ lower: String) -> Bool {
        let fillers = ["thanks", "thank you", "ok", "okay", "cool", "nice", "great", "got it", "sounds good",
                       "hello", "hi", "hey", "good morning", "good night", "lol", "haha", "yes", "no", "sure",
                       "never mind", "nvm", "test", "testing"]
        let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        return fillers.contains(stripped) || stripped.count < 4
    }

    // MARK: - Temporal heuristics

    /// "this week / today / right now / tomorrow / until Friday" ⇒ this is
    /// working context, not a permanent fact. Returns the category to
    /// actually use plus an expiry.
    static func applyTemporalHeuristics(content: String, category: MemoryCategory, now: Date) -> (MemoryCategory, Date?) {
        let l = content.lowercased()
        let shortHorizons = ["today", "right now", "this morning", "this afternoon", "tonight", "at the moment", "currently"]
        let weekHorizons = ["this week", "for the week", "until friday", "until monday", "next few days", "this sprint", "for now"]
        let calendar = Calendar.current

        if shortHorizons.contains(where: l.contains) {
            return (.workingContext, calendar.date(byAdding: .day, value: 1, to: now))
        }
        if weekHorizons.contains(where: l.contains) {
            return (.workingContext, calendar.date(byAdding: .day, value: 7, to: now))
        }
        if l.contains("this month") || l.contains("until the end of the month") {
            return (.workingContext, calendar.date(byAdding: .day, value: 30, to: now))
        }
        return (category, nil)
    }

    // MARK: - Text shaping

    /// Light first-person → declarative rewrite so a memory reads correctly
    /// with no surrounding context. Deliberately conservative — it never
    /// invents facts, just tidies phrasing.
    static func canonicalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
        if t.lowercased().hasPrefix("that ") { t = String(t.dropFirst(5)) }
        guard let first = t.first else { return t }
        t = String(first).uppercased() + t.dropFirst()
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }

    /// Capitalised words and quoted spans → entity tags for retrieval.
    static func entities(in text: String) -> [String] {
        var found: Set<String> = []
        // Quoted spans.
        for m in text.matches(of: /["'“”‘’]([^"'“”‘’]{2,40})["'“”‘’]/) {
            found.insert(String(m.1).lowercased())
        }
        // Capitalised tokens not at sentence start.
        let tokens = text.split(separator: " ")
        for (i, token) in tokens.enumerated() {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()"))
            guard word.count >= 2, let f = word.first, f.isUppercase else { continue }
            if i == 0 && word.allSatisfy({ $0.isUppercase || $0.isLowercase }) && word.dropFirst().allSatisfy({ $0.isLowercase }) {
                continue // ordinary sentence-initial word
            }
            found.insert(word.lowercased())
        }
        return Array(found).sorted()
    }
}
