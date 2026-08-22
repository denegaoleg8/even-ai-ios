import Foundation

/// One candidate reply attached to a `ConversationTurn` — the speaker's
/// own language plus a short Ukrainian gloss, matching the product spec
/// (each G2 suggested reply shows both). `ordering` is the authoritative
/// display order among a turn's replies (0-based), kept explicit rather
/// than relying on array index — a future ranking/filtering step can
/// reorder or drop replies without silently changing what each one's
/// stated position means.
struct SuggestedReply: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var originalLanguageText: String
    var ukrainianText: String
    var ordering: Int

    init(
        id: UUID = UUID(),
        originalLanguageText: String,
        ukrainianText: String,
        ordering: Int
    ) {
        self.id = id
        self.originalLanguageText = originalLanguageText
        self.ukrainianText = ukrainianText
        self.ordering = ordering
    }
}
