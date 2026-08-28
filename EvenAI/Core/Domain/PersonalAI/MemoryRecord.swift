import Foundation

/// The single, stable unit of Personal AI long-term memory. One record = one
/// fact / preference / project note / person note / episode / archived
/// excerpt. Pure value type — no persistence, networking, or vendor
/// dependency — so the exact same struct round-trips through the Phase 1
/// local JSON store and, unchanged, through the Phase 2 cloud.
///
/// ## Provenance is not optional
///
/// `sourceConversationIDs` / `sourceMessageIDs` always point back to where a
/// record came from. An `inferredFromConversation` record that can't cite a
/// source is a bug in the extractor, not a valid record. The Memory Center
/// shows this chain so a user can audit "why does it think this".
///
/// ## Sync-ready by construction
///
/// `id` (client UUID, stable forever), `remoteID`, `revision`, `syncState`
/// and `deletedAt` are carried from day one. Phase 1 never sets them to
/// anything but the local defaults, but their presence means the Phase 2
/// sync engine adds behaviour, not columns.
struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    // MARK: Identity & sync
    let id: UUID
    /// Server-assigned id once synced. `nil` in Phase 1.
    var remoteID: String?
    /// Monotonic per-record edit counter — the basis for Phase 2 conflict
    /// detection. Bumped by `touch()`.
    var revision: Int
    var syncState: MemorySyncState
    /// Tombstone marker. Non-nil ⇒ `status == .deleted`.
    var deletedAt: Date?
    /// Owning user. `nil` == the single local user in Phase 1; the field
    /// exists so per-user isolation is an architecture fact, not a retrofit.
    var ownerID: String?

    // MARK: Classification
    var category: MemoryCategory
    var scope: MemoryScope

    // MARK: Content
    /// The canonical, self-contained statement of the memory, written so it
    /// reads correctly with no surrounding context ("The EvenAI launch is
    /// planned for October 2026", not "moved to October").
    var canonicalContent: String
    /// Optional structured fields — e.g. `["projectID": "...", "month":
    /// "october"]`. Kept `[String: String]` (not `Any`) so the record stays
    /// `Codable`/`Hashable`/`Sendable` with no type erasure — same choice
    /// `ConversationTurn.metadata` already makes.
    var structured: [String: String]
    /// Lowercased entity tags (project names, people, product names) used by
    /// retrieval to connect a new question to older context.
    var entities: [String]

    // MARK: Trust & ranking signals
    var createdAt: Date
    var updatedAt: Date
    /// Last time retrieval actually surfaced this record. Feeds recency
    /// scoring; `nil` until first use.
    var lastUsedAt: Date?
    /// 0…1 — how sure we are the record is accurate.
    var confidence: Double
    /// 0…1 — how much it should be weighted when relevant.
    var importance: Double
    /// The user explicitly confirmed (or authored) this.
    var userConfirmed: Bool
    /// Pinned records are always eligible and rank-boosted.
    var pinned: Bool
    /// User can disable without deleting — excluded from retrieval while off.
    var enabled: Bool
    var status: MemoryStatus

    // MARK: Temporal
    /// Non-nil for `workingContext` and any explicitly time-boxed memory.
    /// A record with `expiresAt <= now` never enters retrieval and is
    /// archived by `MemoryMaintenance`.
    var expiresAt: Date?

    // MARK: Provenance & merge history
    var sourceConversationIDs: [UUID]
    var sourceMessageIDs: [UUID]
    /// This record replaced `supersedesID` (a now-`.superseded` record).
    var supersedesID: UUID?
    /// This record was replaced by `supersededByID`.
    var supersededByID: UUID?

    // MARK: Derived-data metadata (Phase 2)
    /// The `EmbeddingProviding.modelIdentifier` that produced this record's
    /// semantic vector, if any. Purely metadata — the canonical memory is
    /// `canonicalContent`; a lost or stale vector is rebuilt, never a data
    /// loss. `nil` when no embedding exists (the Phase 2 default). Optional
    /// so Phase 1 JSON without this key still decodes.
    var embeddingModelVersion: String?

    init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        revision: Int = 0,
        syncState: MemorySyncState = .localOnly,
        deletedAt: Date? = nil,
        ownerID: String? = nil,
        category: MemoryCategory,
        scope: MemoryScope = .global,
        canonicalContent: String,
        structured: [String: String] = [:],
        entities: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        confidence: Double = 0.6,
        importance: Double = 0.5,
        userConfirmed: Bool = false,
        pinned: Bool = false,
        enabled: Bool = true,
        status: MemoryStatus = .active,
        expiresAt: Date? = nil,
        sourceConversationIDs: [UUID] = [],
        sourceMessageIDs: [UUID] = [],
        supersedesID: UUID? = nil,
        supersededByID: UUID? = nil,
        embeddingModelVersion: String? = nil
    ) {
        self.id = id
        self.remoteID = remoteID
        self.embeddingModelVersion = embeddingModelVersion
        self.revision = revision
        self.syncState = syncState
        self.deletedAt = deletedAt
        self.ownerID = ownerID
        self.category = category
        self.scope = scope
        self.canonicalContent = canonicalContent
        self.structured = structured
        self.entities = entities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.confidence = confidence
        self.importance = importance
        self.userConfirmed = userConfirmed
        self.pinned = pinned
        self.enabled = enabled
        self.status = status
        self.expiresAt = expiresAt
        self.sourceConversationIDs = sourceConversationIDs
        self.sourceMessageIDs = sourceMessageIDs
        self.supersedesID = supersedesID
        self.supersededByID = supersededByID
    }
}

extension MemoryRecord: PersonalCloudSyncable {
    static var recordKind: PersonalRecordKind { .memory }
}

extension MemoryRecord {
    /// Whether this record may be considered by retrieval *right now* — the
    /// one place the "active + enabled + not expired" rule is expressed.
    func isRetrievable(now: Date = .now) -> Bool {
        guard status == .active, enabled, deletedAt == nil else { return false }
        if let expiresAt, expiresAt <= now { return false }
        return true
    }

    /// Whether `expiresAt` has passed — used by `MemoryMaintenance` to move
    /// the record to `.archived`.
    func isExpired(now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Returns a copy with `updatedAt` set and `revision` bumped — every
    /// mutation of a stored record should go through this so Phase 2 sync
    /// always sees a monotonic revision.
    func touched(now: Date = .now) -> MemoryRecord {
        var copy = self
        copy.updatedAt = now
        copy.revision += 1
        if copy.syncState == .synced { copy.syncState = .pendingPush }
        return copy
    }

    /// Rough token estimate for context budgeting — deliberately cheap
    /// (chars / 4), not a real tokenizer. Good enough to keep a prompt
    /// under budget.
    var approximateTokenCount: Int {
        max(1, canonicalContent.count / 4)
    }
}
