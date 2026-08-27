import Foundation

/// One user↔assistant round in a Personal AI conversation (or, for the G2
/// surface, one finalized speaker turn paired with what was shown). The unit
/// the `MemoryExtracting` pipeline inspects after a meaningful exchange, and
/// the unit archived into `conversationArchive` memory.
///
/// Deliberately surface-agnostic: G2 maps a `ConversationTurn` onto this;
/// Personal AI Chat maps its own messages. One extractor, one archive.
struct PersonalAIExchange: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// The conversation this exchange belongs to — the key
    /// "do not remember" exclusion and archive retrieval work against.
    var conversationID: UUID
    var surface: PersonalAISurface
    var timestamp: Date
    /// What the user said / the speaker turn text.
    var userText: String
    /// What the Personal AI replied, if anything (nil for a pure
    /// capture-only G2 turn).
    var assistantText: String?
    /// Optional message ids, for provenance back-links.
    var userMessageID: UUID?
    var assistantMessageID: UUID?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        surface: PersonalAISurface,
        timestamp: Date = .now,
        userText: String,
        assistantText: String? = nil,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.surface = surface
        self.timestamp = timestamp
        self.userText = userText
        self.assistantText = assistantText
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
    }
}

/// A short, self-contained excerpt pulled from `conversationArchive` memory
/// and offered to the context builder — "you discussed X on date Y".
struct ConversationExcerpt: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var conversationID: UUID
    var timestamp: Date
    var text: String
    /// Retrieval score that got it here (0…1) — surfaced for debugging /
    /// the Memory Center, never logged raw.
    var relevance: Double

    init(id: UUID = UUID(), conversationID: UUID, timestamp: Date = .now, text: String, relevance: Double) {
        self.id = id
        self.conversationID = conversationID
        self.timestamp = timestamp
        self.text = text
        self.relevance = relevance
    }
}
