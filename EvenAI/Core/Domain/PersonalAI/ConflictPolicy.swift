import Foundation

/// Deterministic conflict resolution, chosen per record kind — **not** blind
/// last-write-wins. The policy for a kind is fixed and total, so the same
/// two conflicting versions always resolve the same way regardless of which
/// device syncs first.
enum ConflictPolicy: Equatable, Sendable {
    /// Run `MemoryMerger.reconcile` (duplicate → collapse, contradiction →
    /// supersede, else keep the higher-revision one). Used for memories,
    /// projects, people, knowledge, episodes.
    case semanticMerge
    /// Keep both rules unless their text is a duplicate; when duplicate,
    /// `enabled = local || server`, text = whichever was updated last.
    case ruleUnion
    /// Messages are append-only history — a conflict means both sides
    /// exist; order by `(timestamp, id)`, never overwrite text.
    case appendOnly
    /// Conversation metadata: highest `revision` wins; tie broken by newest
    /// `updatedAt`, then by `id` for total determinism.
    case highestRevisionThenNewest
    /// Single per-user record (style profile): newest `updatedAt` wins; tie
    /// broken by `id` string comparison.
    case newestWins

    static func forKind(_ kind: PersonalRecordKind) -> ConflictPolicy {
        switch kind {
        case .memory: return .semanticMerge
        case .rule: return .ruleUnion
        case .message: return .appendOnly
        case .conversation: return .highestRevisionThenNewest
        case .styleProfile: return .newestWins
        }
    }
}
