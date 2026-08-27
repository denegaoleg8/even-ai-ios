import Foundation

/// Turns the structured pieces the context builder assembled into the
/// compact, token-budgeted block a model provider consumes. Sections are
/// emitted in `PersonalAIPriority` order and trimmed lowest-priority-first
/// to fit the budget, so "current instruction > active rule > retrieved
/// memory > learned style > default" is enforced structurally, not by hope.
enum PersonalAIContextRenderer {

    struct Input {
        var currentInstruction: String?      // command detected in this very message
        var rules: [Rule]
        var projects: [MemoryRecord]
        var people: [MemoryRecord]
        var otherMemories: [MemoryRecord]
        var excerpts: [ConversationExcerpt]
        var styleInstructions: String
        var tokenBudget: Int
        var memoryDisabled: Bool
    }

    static func render(_ input: Input) -> (text: String, trace: [String]) {
        var trace: [String] = []
        var sections: [(priority: Int, text: String)] = []

        // The current-message instruction and the user's standing rules are
        // explicit instructions, not "memory about the user" — they are
        // rendered even when recall is turned off. Only retrieved
        // memories / style / archive excerpts are suppressed by
        // `memoryDisabled`.
        if input.memoryDisabled {
            trace.append("memoryDisabled")
        }

        if let instruction = input.currentInstruction, !instruction.isEmpty {
            sections.append((0, "The user just gave you this instruction — follow it for this reply, above any stored preference:\n• \(instruction)"))
        }

        if !input.rules.isEmpty {
            let lines = input.rules.prefix(12).map { "• \($0.text)" }.joined(separator: "\n")
            sections.append((1, "Standing instructions from the user (always follow):\n\(lines)"))
            trace.append("rules=\(input.rules.count)")
        }

        if input.memoryDisabled {
            sections.append((2, "Personal memory is turned off — do not rely on stored facts about the user; answer from this conversation and the instructions above only."))
        }

        if !input.memoryDisabled, !input.projects.isEmpty {
            let lines = input.projects.prefix(4).map { "• \($0.canonicalContent)" }.joined(separator: "\n")
            sections.append((2, "Relevant project context:\n\(lines)"))
            trace.append("projects=\(input.projects.count)")
        }

        if !input.memoryDisabled, !input.people.isEmpty {
            let lines = input.people.prefix(4).map { "• \($0.canonicalContent)" }.joined(separator: "\n")
            sections.append((2, "Relevant people:\n\(lines)"))
            trace.append("people=\(input.people.count)")
        }

        if !input.memoryDisabled, !input.otherMemories.isEmpty {
            let lines = input.otherMemories.prefix(8).map { "• \($0.canonicalContent)" }.joined(separator: "\n")
            sections.append((2, "Other things you know about the user that may be relevant:\n\(lines)"))
            trace.append("memories=\(input.otherMemories.count)")
        }

        if !input.memoryDisabled, !input.excerpts.isEmpty {
            let lines = input.excerpts.prefix(3).map { "• (\(Self.relativeDay($0.timestamp))) \($0.text)" }.joined(separator: "\n")
            sections.append((2, "From earlier conversations:\n\(lines)"))
            trace.append("excerpts=\(input.excerpts.count)")
        }

        if !input.memoryDisabled, !input.styleInstructions.isEmpty {
            sections.append((3, "Response style: \(input.styleInstructions)"))
            trace.append("style")
        }

        // Budget trim — drop from the bottom (lowest priority) until it fits.
        var ordered = sections.sorted { $0.priority < $1.priority }
        func assembled() -> String { ordered.map(\.text).joined(separator: "\n\n") }
        while approxTokens(assembled()) > max(0, input.tokenBudget - antiGenericGuidanceTokens), ordered.count > 1 {
            let removed = ordered.removeLast()
            trace.append("dropped_for_budget(priority=\(removed.priority))")
        }

        // The anti-generic-reply guidance is appended AFTER the trim and is
        // never dropped — it is the production mechanism that keeps replies
        // from collapsing to "thanks for sharing" / "that's interesting".
        var body = ordered.map(\.text)
        body.append(antiGenericGuidance)
        trace.append("guidance")

        let text = "You are the user's persistent Personal AI. " + body.joined(separator: "\n\n")
        trace.append("approxTokens=\(approxTokens(text))")
        return (text, trace)
    }

    static let antiGenericGuidance = "Use what you know naturally — connect the user's message to relevant context, draw implications, and ask a genuinely useful follow-up when appropriate. Do not narrate that you are using memory, and never reply with empty acknowledgements like \"thanks for sharing\" or \"that's interesting\" when you have something substantive to say."

    static var antiGenericGuidanceTokens: Int { approxTokens(antiGenericGuidance) }

    static func approxTokens(_ s: String) -> Int { max(0, s.count / 4) }

    static func relativeDay(_ date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<30: return "\(days / 7) week(s) ago"
        default: return "\(days / 30) month(s) ago"
        }
    }
}
