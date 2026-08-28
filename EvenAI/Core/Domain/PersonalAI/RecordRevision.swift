import Foundation

/// One entry in a record's version history. Written every time a syncable
/// record's content is replaced — by a user edit, a merge/supersede, or a
/// sync conflict resolution — so an important memory is never destructively
/// overwritten and a future "undo / restore this version" is possible.
///
/// `previousPayloadJSON` is the full serialized state of the record *before*
/// this change, so a restore is a straight decode-and-write. Pure value
/// type; it travels in `PersonalDataBundle` and (Phase 3) the
/// `memory_revisions` table.
struct RecordRevision: Identifiable, Codable, Hashable, Sendable {
    /// The revision's own id (`revisionID`).
    let id: UUID
    /// The record this revision belongs to.
    var recordID: UUID
    var recordKind: PersonalRecordKind
    /// The `revision` number the record held at the moment this history
    /// entry was captured (i.e. the version being superseded).
    var version: Int
    var changedAt: Date
    var source: MemorySource
    /// Machine-readable reason, never free-form user text and never memory
    /// content — e.g. `"user-edit"`, `"merge:supersede"`,
    /// `"sync:conflict-resolution"`, `"import:merge"`.
    var reason: String
    /// The record's complete serialized state *before* the change that
    /// produced this revision.
    var previousPayloadJSON: String
    var previousRevision: Int?

    init(
        id: UUID = UUID(),
        recordID: UUID,
        recordKind: PersonalRecordKind,
        version: Int,
        changedAt: Date = .now,
        source: MemorySource,
        reason: String,
        previousPayloadJSON: String,
        previousRevision: Int? = nil
    ) {
        self.id = id
        self.recordID = recordID
        self.recordKind = recordKind
        self.version = version
        self.changedAt = changedAt
        self.source = source
        self.reason = reason
        self.previousPayloadJSON = previousPayloadJSON
        self.previousRevision = previousRevision
    }

    /// How many revisions to retain per record. `userConfirmed` records keep
    /// their full history (deliberate corrections matter); inferred records
    /// keep the most recent few to bound growth. Enforced by whoever writes
    /// the revision log, not by this type.
    static let confirmedRetention = Int.max
    static let inferredRetention = 10
}
