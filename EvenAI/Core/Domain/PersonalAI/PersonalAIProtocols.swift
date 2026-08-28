import Foundation

/// Decides whether a finished exchange contains anything worth remembering
/// long-term, and proposes `MemoryCandidate`s for it. Testable in isolation:
/// given an exchange and the current memory, it returns proposals — it never
/// writes anything itself.
///
/// Phase 1 ships `HeuristicMemoryExtractor` (deterministic: explicit
/// commands + a small set of durable-fact patterns + hard secret/filler
/// rejection). A future LLM-backed extractor is a drop-in replacement.
protocol MemoryExtracting: Sendable {
    func extract(
        from exchange: PersonalAIExchange,
        existing: [MemoryRecord],
        excludedConversationIDs: Set<UUID>,
        memoryEnabled: Bool
    ) async -> [MemoryCandidate]
}

/// **The single personalization contract.** Personal AI Chat uses it; the
/// future G2 personalization seam uses the *same* protocol with the *same*
/// request/response types, differing only in `PersonalAIContextRequest
/// .surface`. There is deliberately no second builder.
protocol PersonalAIContextBuilding: Sendable {
    func buildContext(_ request: PersonalAIContextRequest) async -> PersonalAIContext
}

/// Persistence for Personal AI Chat's own conversation history — separate
/// from Glasses Chat (`LocalGlassesChatStore`) and AI Chat (`ChatServicing`),
/// because Personal AI Chat is its own surface with its own retention and
/// "do not remember" semantics.
protocol PersonalAIConversationStore: Sendable {
    func loadConversation(id: UUID) async -> [PersonalAIChatMessage]
    func append(_ message: PersonalAIChatMessage, conversationID: UUID) async
    func replaceConversation(id: UUID, messages: [PersonalAIChatMessage]) async
    /// The most recent conversation id, or a freshly created one — Personal
    /// AI Chat "always opens".
    func currentConversationID() async -> UUID
    func startNewConversation() async -> UUID

    // MARK: Phase 2 — sync / backup / restore awareness

    /// All conversation-level records (metadata + `doNotRemember` flag).
    func allConversations() async -> [PersonalAIConversation]
    /// All messages across all conversations, including tombstones.
    func allMessages() async -> [PersonalAIChatMessage]
    /// Insert or replace a conversation record (from sync / restore).
    func upsertConversation(_ conversation: PersonalAIConversation) async
    /// Insert or replace messages by `id` (from sync / restore) — never
    /// duplicates, honours `deletedAt`.
    func upsertMessages(_ messages: [PersonalAIChatMessage]) async
    /// Mark a conversation "do not remember"; also flags its messages
    /// ineligible and excludes them from upload/export.
    func setDoNotRemember(_ conversationID: UUID, _ value: Bool) async
    /// Replace the entire conversation dataset (restore `.replaceAll`).
    func replaceAllConversations(_ conversations: [PersonalAIConversation], messages: [PersonalAIChatMessage]) async
    /// Remove every conversation and message (account deletion).
    func wipe() async
}
