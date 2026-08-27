import Foundation

/// The request every personalization consumer hands to
/// `PersonalAIContextBuilding`. Personal AI Chat and the (future) G2 seam
/// build one of these — the surface field is the only structural difference
/// between them.
struct PersonalAIContextRequest: Hashable, Sendable {
    var surface: PersonalAISurface
    /// The current user message / finalized speaker turn.
    var userMessage: String
    /// Recent conversation, oldest-first, as plain text lines
    /// ("You: …" / "AI: …" or just turn text for G2).
    var recentConversation: [String]
    /// The conversation this belongs to — used to honour "do not remember"
    /// and to avoid retrieving the very conversation you're in as "history".
    var conversationID: UUID?
    var projectHints: [String]
    var personHints: [String]
    /// Approximate token ceiling for the assembled Personal AI context
    /// block. The builder trims to fit, dropping lowest-priority material
    /// first.
    var tokenBudget: Int
    var now: Date

    init(
        surface: PersonalAISurface,
        userMessage: String,
        recentConversation: [String] = [],
        conversationID: UUID? = nil,
        projectHints: [String] = [],
        personHints: [String] = [],
        tokenBudget: Int = 1200,
        now: Date = .now
    ) {
        self.surface = surface
        self.userMessage = userMessage
        self.recentConversation = recentConversation
        self.conversationID = conversationID
        self.projectHints = projectHints
        self.personHints = personHints
        self.tokenBudget = tokenBudget
        self.now = now
    }
}

/// The assembled, token-budgeted personalization context. `systemPromptText`
/// is what a model provider actually consumes; the structured fields are for
/// tests, the Memory Center, and non-LLM providers that want to reason over
/// the parts directly.
struct PersonalAIContext: Hashable, Sendable {
    /// Imperative instructions, already ordered by `PersonalAIPriority`
    /// (current-message instruction first, then stored rules).
    var activeRules: [Rule]
    /// Facts/preferences/knowledge retrieval judged relevant.
    var relevantMemories: [MemoryRecord]
    /// `projects` records among the relevant set, called out separately so
    /// a consumer can foreground "what are they working on".
    var relevantProjects: [MemoryRecord]
    /// `people` records among the relevant set.
    var relevantPeople: [MemoryRecord]
    /// Excerpts pulled from the conversation archive.
    var historicalExcerpts: [ConversationExcerpt]
    /// Rendered natural-language style guidance ("Reply in Ukrainian. Keep
    /// it short and direct. Never open with 'thanks for sharing'.").
    var styleInstructions: String
    /// The final compact block a model provider is given.
    var systemPromptText: String
    /// Whether memory was globally disabled when this was built — a
    /// consumer can surface "memory is off".
    var memoryDisabled: Bool
    /// Structured, content-free trace of what happened during the build
    /// ("retrieved 3/12 memories", "dropped 2 for budget"). Safe to log.
    var buildTrace: [String]

    static let empty = PersonalAIContext(
        activeRules: [],
        relevantMemories: [],
        relevantProjects: [],
        relevantPeople: [],
        historicalExcerpts: [],
        styleInstructions: "",
        systemPromptText: "",
        memoryDisabled: false,
        buildTrace: []
    )

    /// True when the builder found *something* worth personalising with —
    /// consumers use this to decide "should I even mention I know things".
    var hasPersonalization: Bool {
        !activeRules.isEmpty || !relevantMemories.isEmpty
            || !historicalExcerpts.isEmpty || !styleInstructions.isEmpty
    }
}
