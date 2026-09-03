import Foundation

/// Everything `MemoryRetriever` needs to rank memory for one request. Built
/// by `PersonalAIContextBuilding` from a `PersonalAIContextRequest`; kept as
/// its own type so retrieval can be tested in complete isolation from the
/// builder.
struct RetrievalQuery: Hashable, Sendable {
    /// The current user message / speaker turn — the primary relevance
    /// signal.
    var text: String
    /// Recent conversation text (oldest-first), folded in at a lower weight
    /// so retrieval tracks the thread, not just the last line.
    var recentContext: [String]
    var surface: PersonalAISurface
    /// Lowercased project entity/name hints the caller already knows
    /// (e.g. the active project in the UI). A hard boost, not a filter.
    var projectHints: [String]
    /// Lowercased people hints.
    var personHints: [String]
    var now: Date
    /// Max records to return after ranking.
    var limit: Int
    /// Records scoring below this are dropped entirely — the mechanism that
    /// keeps unrelated memory (last week's travel note) out of an unrelated
    /// prompt.
    var minScore: Double
    /// The message is asking to recall a stored **profile / identity** fact
    /// ("what is my name?", "де я живу?", "was mache ich beruflich?"). Set by
    /// the context builder from `ProfileQuestionDetector`. When true,
    /// `.profile` records are let past retrieval's generic topical-connection
    /// gate for this turn — they still obey `minScore`, `isRetrievable`,
    /// scope and owner — so a Personal AI can answer identity questions with
    /// no semantic model, even cross-lingually. `false` ⇒ retrieval is
    /// exactly as before.
    var profileLookup: Bool

    init(
        text: String,
        recentContext: [String] = [],
        surface: PersonalAISurface,
        projectHints: [String] = [],
        personHints: [String] = [],
        now: Date = .now,
        limit: Int = 8,
        minScore: Double = 0.12,
        profileLookup: Bool = false
    ) {
        self.text = text
        self.recentContext = recentContext
        self.surface = surface
        self.projectHints = projectHints
        self.personHints = personHints
        self.now = now
        self.limit = limit
        self.minScore = minScore
        self.profileLookup = profileLookup
    }
}

/// A memory record plus the score retrieval gave it and a breakdown of why —
/// the breakdown is for tests and the Memory Center's "why was this used"
/// view; it is never emitted to `DiagnosticTrace` with content attached.
struct ScoredMemory: Identifiable, Hashable, Sendable {
    var record: MemoryRecord
    var score: Double
    var components: [String: Double]

    var id: UUID { record.id }
}

/// A filter passed to `PersonalMemoryStore.memories(matching:)`. All fields
/// are AND-combined; `nil` means "don't filter on this".
struct MemoryQuery: Hashable, Sendable {
    var categories: Set<MemoryCategory>?
    var statuses: Set<MemoryStatus>?
    var scope: MemoryScope?
    var includeDisabled: Bool
    var searchText: String?

    init(
        categories: Set<MemoryCategory>? = nil,
        statuses: Set<MemoryStatus>? = [.active],
        scope: MemoryScope? = nil,
        includeDisabled: Bool = false,
        searchText: String? = nil
    ) {
        self.categories = categories
        self.statuses = statuses
        self.scope = scope
        self.includeDisabled = includeDisabled
        self.searchText = searchText
    }

    static let all = MemoryQuery(statuses: nil, includeDisabled: true)
}
