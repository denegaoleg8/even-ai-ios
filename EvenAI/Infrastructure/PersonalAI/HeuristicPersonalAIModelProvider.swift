import Foundation

/// Deterministic, no-AI-framework `PersonalAIModelProviding` — the tier that
/// always works, on any device, offline. It does not "chat" fluently, but it
/// **actively uses the retrieved context**: it connects the user's message
/// to known project/person context, reflects any relevant memory, respects
/// rules and style, and asks a concrete follow-up. It never emits the empty
/// acknowledgements the product brief calls out ("thanks for sharing").
///
/// This exists so Personal AI Chat is useful on a device without Apple
/// Intelligence, and so the whole pipeline is testable without a model.
struct HeuristicPersonalAIModelProvider: PersonalAIModelProviding {

    init() {}

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        let context = request.personalContext
        let message = request.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return PersonalAIGenerationResult(text: "What would you like to talk about?", provider: .heuristic, usedPersonalization: false)
        }

        // 0. Direct answer to a stored profile / identity question ("what is
        //    my name?"). No cloud model, no Apple Intelligence. If the fact
        //    isn't on file we do NOT fabricate one — fall through to the
        //    normal safe behaviour.
        let asks = ProfileQuestionDetector().aspects(in: message)
        if !asks.isEmpty, !context.memoryDisabled {
            let profileFacts = context.relevantMemories.filter { $0.category == .profile }
            if let answer = Self.directProfileAnswer(asks: asks, facts: profileFacts) {
                return PersonalAIGenerationResult(text: answer, provider: .heuristic, usedPersonalization: true)
            }
        }

        var lines: [String] = []
        var usedPersonalization = false

        // 1. Connect to the most relevant project / person / memory.
        if let project = context.relevantProjects.first {
            lines.append("This looks related to \(Self.shortRef(project.canonicalContent)).")
            usedPersonalization = true
        } else if let person = context.relevantPeople.first {
            lines.append("On \(Self.shortRef(person.canonicalContent)):")
            usedPersonalization = true
        } else if let memory = context.relevantMemories.first {
            lines.append("Given that \(Self.lowerFirst(memory.canonicalContent))")
            usedPersonalization = true
        }

        // 2. Reflect an earlier conversation if one is relevant.
        if let excerpt = context.historicalExcerpts.first {
            lines.append("You raised something similar before — \(Self.lowerFirst(excerpt.text)) Does this build on that?")
            usedPersonalization = true
        }

        // 3. Substantive body — echo the ask and offer a direction.
        if Self.isQuestion(message) {
            lines.append("Here's how I'd approach \"\(Self.trimForQuote(message))\": break it into the concrete blockers, tackle the one with the most leverage first, and tell me what you've already tried so I can be specific.")
        } else if !usedPersonalization {
            lines.append("Noted. The most useful next step is probably to decide what outcome you want from this — tell me that and I can help you get there.")
        } else {
            lines.append("Tell me what specifically is going wrong and what you've tried, and I'll help you work through it.")
        }

        var text = lines.joined(separator: " ")
        text = Self.applyStyle(text, context: context)
        text = Self.applyRulesAndAvoidances(text, context: context)

        return PersonalAIGenerationResult(
            text: text,
            provider: .heuristic,
            usedPersonalization: usedPersonalization || !context.activeRules.isEmpty
        )
    }

    // MARK: - Direct profile answers

    /// Answers a profile question from the retrieved `.profile` facts. Returns
    /// `nil` when nothing on file matches — the caller must not invent a value.
    static func directProfileAnswer(asks: Set<ProfileAspect>, facts: [MemoryRecord]) -> String? {
        guard !facts.isEmpty else { return nil }
        var parts: [String] = []
        // Deterministic order so a multi-aspect question reads sensibly.
        for aspect in [ProfileAspect.name, .occupation, .location, .language] where asks.contains(aspect) {
            guard let fact = factMatching(aspect, in: facts) ?? soleFact(facts, whenAsking: asks) else { continue }
            let value = valueFor(aspect, in: fact.canonicalContent)
            switch aspect {
            case .name:       parts.append(value.map { "Your name is \($0)." } ?? onFile(fact))
            case .location:   parts.append(value.map { "You live in \($0)." } ?? onFile(fact))
            case .occupation: parts.append(value.map { "You work as \($0)." } ?? onFile(fact))
            case .language:   parts.append(value.map { "You speak \($0)." } ?? onFile(fact))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func onFile(_ fact: MemoryRecord) -> String {
        "From what you've told me: \(shortRef(fact.canonicalContent))"
    }

    /// The single profile fact to fall back to when only one aspect is asked
    /// and there is exactly one profile fact stored.
    private static func soleFact(_ facts: [MemoryRecord], whenAsking asks: Set<ProfileAspect>) -> MemoryRecord? {
        (asks.count == 1 && facts.count == 1) ? facts.first : nil
    }

    private static func factMatching(_ aspect: ProfileAspect, in facts: [MemoryRecord]) -> MemoryRecord? {
        let markers = ProfileQuestionDetector.storageMarkers(for: aspect)
        return facts.first { fact in
            let l = CommandInterpreter.normalize(fact.canonicalContent.lowercased())
            return markers.contains(where: l.contains)
        }
    }

    /// Best-effort extraction of the value that follows a storage marker,
    /// mapping the match back onto the original-cased string.
    static func valueFor(_ aspect: ProfileAspect, in content: String) -> String? {
        let lower = CommandInterpreter.normalize(content.lowercased())
        for marker in ProfileQuestionDetector.storageMarkers(for: aspect) {
            guard let r = lower.range(of: marker) else { continue }
            let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
            guard offset <= content.count else { continue }
            let start = content.index(content.startIndex, offsetBy: offset)
            var rest = String(content[start...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:—–-\"'"))
            // Drop a leading connector word ("є", "is", "to", "a", "an", "als").
            for connector in ["is ", "a ", "an ", "als ", "to ", "як ", "є "] where rest.lowercased().hasPrefix(connector) {
                rest = String(rest.dropFirst(connector.count))
            }
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:—–-\"'"))
            guard !rest.isEmpty, rest.count <= 60 else { return rest.isEmpty ? nil : String(rest.prefix(60)) }
            return rest
        }
        return nil
    }

    // MARK: - Shaping

    static func applyStyle(_ text: String, context: PersonalAIContext) -> String {
        var out = text
        let style = context.styleInstructions.lowercased()
        if style.contains("keep it short") {
            // Collapse to the first two sentences.
            let sentences = out.split(separator: ".", omittingEmptySubsequences: true)
            if sentences.count > 2 {
                out = sentences.prefix(2).joined(separator: ".").trimmingCharacters(in: .whitespaces) + "."
            }
        }
        return out
    }

    static func applyRulesAndAvoidances(_ text: String, context: PersonalAIContext) -> String {
        var out = text
        // Honour "phrases to avoid" surfaced through style instructions or rules.
        let banned = Self.bannedPhrases(context)
        for phrase in banned {
            out = out.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
    }

    static func bannedPhrases(_ context: PersonalAIContext) -> [String] {
        var phrases = ["thanks for sharing", "that's interesting", "i'm here if you need anything", "i'm here to help"]
        for rule in context.activeRules {
            if let m = rule.text.firstMatch(of: /["'“”‘’](.+?)["'“”‘’]/) {
                phrases.append(String(m.1))
            }
        }
        return phrases
    }

    static func isQuestion(_ s: String) -> Bool {
        s.hasSuffix("?") || ["how ", "why ", "what ", "when ", "where ", "should i", "can you", "could you", "help me"].contains { s.lowercased().hasPrefix($0) }
    }

    static func shortRef(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return t.count > 90 ? String(t.prefix(90)) + "…" : t
    }
    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).lowercased() + s.dropFirst()
    }
    static func trimForQuote(_ s: String) -> String {
        s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
