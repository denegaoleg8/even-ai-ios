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
