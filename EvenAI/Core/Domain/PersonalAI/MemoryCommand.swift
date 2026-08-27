import Foundation

/// A memory-affecting intent detected in a user message by
/// `CommandInterpreter`. Semantic, not slash-command: "remember that…",
/// "from now on…", "forget about…" all map here without exact wording.
enum MemoryCommand: Hashable, Sendable {
    /// "remember that X", "keep in mind X", "note that X".
    case remember(content: String, suggestedCategory: MemoryCategory)
    /// "from now on…", "always…", "never…", "don't…" — a behavioural rule.
    case addRule(text: String, scope: MemoryScope)
    /// "forget about X", "stop remembering X", "delete the memory about X".
    case forget(query: String)
    /// A style directive that should update the style profile immediately
    /// *and* be stored ("keep replies short", "use Ukrainian with me").
    case setStyle(directive: String)

    var isDestructive: Bool {
        if case .forget = self { return true }
        return false
    }
}

/// A proposed memory produced by `MemoryExtracting`, before merge/dedupe.
/// Carries the would-be record plus why it was proposed, so the merger and
/// (eventually) the user can reason about it.
struct MemoryCandidate: Hashable, Sendable {
    var record: MemoryRecord
    /// Short machine rationale ("explicit remember command", "durable
    /// self-fact: 'I work on …'"). Never contains a secret.
    var rationale: String
    /// The command this came from, if any.
    var originatingCommand: MemoryCommand?
    /// Extractor's own confidence this deserves long-term storage (0…1),
    /// distinct from `record.confidence` (accuracy of the content).
    var salience: Double

    init(record: MemoryRecord, rationale: String, originatingCommand: MemoryCommand? = nil, salience: Double = 0.5) {
        self.record = record
        self.rationale = rationale
        self.originatingCommand = originatingCommand
        self.salience = salience
    }
}

/// What `MemoryMerger` decided to do with a candidate relative to existing
/// memory. The store applies exactly one of these per candidate.
enum MergeDecision: Sendable {
    /// No related memory — insert as-is.
    case create(MemoryRecord)
    /// Semantically identical to an existing record — don't insert; the
    /// associated record is the existing one, `touched()` (bumped
    /// `lastUsedAt`/confidence, unioned provenance).
    case duplicate(existingID: UUID, refreshed: MemoryRecord)
    /// Contradicts an existing active record — insert `newRecord` and mark
    /// `supersededID` as `.superseded`. Provenance is unioned onto the new
    /// record.
    case supersede(supersededID: UUID, newRecord: MemoryRecord)
    /// Same subject, complementary detail — replace the existing record
    /// with a merged one (same `id`, `touched()`).
    case mergeInto(existingID: UUID, merged: MemoryRecord)
    /// Rejected (secret, filler, excluded conversation, memory disabled).
    case reject(reason: String)
}
