import Foundation

/// Provider-agnostic abstraction over generating a Personal AI response.
/// **No AI vendor is named here or anywhere in `Core`** — exactly the
/// discipline `SuggestedReplyGenerating` already follows. The user's memory
/// must be portable independently of whichever model answers, so the model
/// is a swappable dependency behind this one method.
///
/// Phase 1 ships `OnDevicePersonalAIModelProvider` (Apple `FoundationModels`
/// when available, a deterministic context-aware fallback otherwise). A
/// future self-hosted or API-backed provider is just another conformer.
protocol PersonalAIModelProviding: Sendable {
    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult
}

struct PersonalAIGenerationRequest: Hashable, Sendable {
    /// The compact personalization block from `PersonalAIContextBuilding`.
    var personalContext: PersonalAIContext
    /// Conversation so far, oldest-first.
    var messages: [PersonalAIChatMessage]
    /// The new user message to respond to.
    var userMessage: String
    var maxOutputTokens: Int

    init(
        personalContext: PersonalAIContext,
        messages: [PersonalAIChatMessage],
        userMessage: String,
        maxOutputTokens: Int = 500
    ) {
        self.personalContext = personalContext
        self.messages = messages
        self.userMessage = userMessage
        self.maxOutputTokens = maxOutputTokens
    }
}

struct PersonalAIGenerationResult: Hashable, Sendable {
    var text: String
    /// Which tier actually answered — surfaced in the UI as a small note,
    /// never as an error.
    var provider: Provider
    /// True if the provider consciously used retrieved memory/rules to
    /// shape the answer (tests assert this when context was available).
    var usedPersonalization: Bool

    enum Provider: String, Hashable, Sendable {
        case onDeviceFoundationModel
        case heuristic
        case cloud
        case fake
    }
}

/// One message in a Personal AI conversation. Separate from Chat's `Message`
/// (which carries `chatID`, `status`, streaming state) — this is the minimal
/// shape the model provider and archive need.
///
/// Phase 2 adds the `PersonalCloudSyncable` fields (`conversationID`,
/// `revision`, `syncState`, `deletedAt`, `ownerID`, `remoteID`) so messages
/// sync and restore alongside memories. All new keys decode with a fallback,
/// so a Phase 1 conversation file still loads.
struct PersonalAIChatMessage: PersonalCloudSyncable, Hashable {
    static var recordKind: PersonalRecordKind { .message }

    enum Role: String, Codable, Hashable, Sendable { case user, assistant, system }

    let id: UUID
    /// The conversation this message belongs to. Phase 1 tracked this only
    /// as the store's dictionary key; Phase 2 makes it explicit on the
    /// record so a message is self-describing for sync / export.
    var conversationID: UUID
    var role: Role
    var text: String
    var timestamp: Date
    /// Set false for a message the user marked (or whose conversation was
    /// marked) "do not remember" — the extractor skips it, and it is
    /// excluded from upload and export.
    var eligibleForMemory: Bool

    // Sync fields (PersonalCloudSyncable)
    var remoteID: String?
    var revision: Int
    var syncState: MemorySyncState
    var deletedAt: Date?
    var ownerID: String?
    /// For messages (append-only history) this tracks tombstone / sync
    /// bookkeeping time; it starts equal to `timestamp`.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        conversationID: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = .now,
        eligibleForMemory: Bool = true,
        remoteID: String? = nil,
        revision: Int = 0,
        syncState: MemorySyncState = .localOnly,
        deletedAt: Date? = nil,
        ownerID: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.eligibleForMemory = eligibleForMemory
        self.remoteID = remoteID
        self.revision = revision
        self.syncState = syncState
        self.deletedAt = deletedAt
        self.ownerID = ownerID
        self.updatedAt = updatedAt ?? timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, role, text, timestamp, eligibleForMemory
        case remoteID, revision, syncState, deletedAt, ownerID, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        eligibleForMemory = try c.decodeIfPresent(Bool.self, forKey: .eligibleForMemory) ?? true
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        syncState = try c.decodeIfPresent(MemorySyncState.self, forKey: .syncState) ?? .localOnly
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? timestamp
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(eligibleForMemory, forKey: .eligibleForMemory)
        try c.encodeIfPresent(remoteID, forKey: .remoteID)
        try c.encode(revision, forKey: .revision)
        try c.encode(syncState, forKey: .syncState)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(ownerID, forKey: .ownerID)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

enum PersonalAIError: Error, Equatable, Sendable {
    case modelUnavailable(reason: String)
    case generationFailed(String)
    case cancelled
    case rejectedContent(reason: String)

    var userFacingMessage: String {
        switch self {
        case .modelUnavailable(let reason):
            return "Personal AI model isn't available right now (\(reason)). Your memory is still being recorded."
        case .generationFailed:
            return "Personal AI couldn't complete that response. Try again."
        case .cancelled:
            return "Cancelled."
        case .rejectedContent(let reason):
            return "That wasn't stored: \(reason)."
        }
    }
}
