import Foundation

/// A Personal AI Chat conversation as a syncable record. Phase 1 tracked
/// conversations only implicitly (a `UUID` key in
/// `LocalPersonalAIConversationStore`); Phase 2 makes them first-class so
/// they survive sync, backup, and new-iPhone restore alongside their
/// messages.
///
/// The messages themselves are `PersonalAIChatMessage` (extended in Phase 2
/// with the same sync fields). This record carries the conversation-level
/// metadata and the `doNotRemember` flag — a `doNotRemember` conversation
/// and its messages are excluded from upload, extraction, and export.
struct PersonalAIConversation: PersonalCloudSyncable, Hashable {
    static var recordKind: PersonalRecordKind { .conversation }

    let id: UUID
    var title: String?
    var createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date?
    var messageCount: Int
    /// "Do Not Remember This Conversation" — see the doc comment.
    var doNotRemember: Bool

    // Sync fields (PersonalCloudSyncable)
    var remoteID: String?
    var revision: Int
    var syncState: MemorySyncState
    var deletedAt: Date?
    var ownerID: String?

    init(
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastMessageAt: Date? = nil,
        messageCount: Int = 0,
        doNotRemember: Bool = false,
        remoteID: String? = nil,
        revision: Int = 0,
        syncState: MemorySyncState = .localOnly,
        deletedAt: Date? = nil,
        ownerID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.doNotRemember = doNotRemember
        self.remoteID = remoteID
        self.revision = revision
        self.syncState = syncState
        self.deletedAt = deletedAt
        self.ownerID = ownerID
    }

    func touched(now: Date = .now) -> PersonalAIConversation {
        var copy = self
        copy.updatedAt = now
        copy.revision += 1
        if copy.syncState == .synced { copy.syncState = .pendingPush }
        return copy
    }
}
