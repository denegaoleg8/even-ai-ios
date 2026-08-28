import Foundation

/// The complete, portable Personal AI dataset — the **one** unit used for:
/// a cloud snapshot, an independent backup, a user export, and a restore.
/// It is a strict superset of the Phase 1 `PersonalMemoryDocument` (nested
/// unchanged), plus conversations, messages, and the version-history log.
///
/// Contains **only** the user's Personal AI content. It never carries auth
/// tokens, refresh tokens, API keys, session secrets, or private keys —
/// those live in the Keychain and are not part of this model.
struct PersonalDataBundle: Codable, Hashable, Sendable {
    var manifest: BackupManifest
    /// Phase 1 document: memories, rules, style profile, and the
    /// memory-enabled / do-not-remember flags. Nested byte-for-byte.
    var memory: PersonalMemoryDocument
    var conversations: [PersonalAIConversation]
    var messages: [PersonalAIChatMessage]
    var revisions: [RecordRevision]

    init(
        manifest: BackupManifest,
        memory: PersonalMemoryDocument = .empty,
        conversations: [PersonalAIConversation] = [],
        messages: [PersonalAIChatMessage] = [],
        revisions: [RecordRevision] = []
    ) {
        self.manifest = manifest
        self.memory = memory
        self.conversations = conversations
        self.messages = messages
        self.revisions = revisions
    }

    /// Record counts by `PersonalRecordKind.rawValue`, for the manifest and
    /// for import validation.
    var recordCounts: [String: Int] {
        [
            PersonalRecordKind.memory.rawValue: memory.records.count,
            PersonalRecordKind.rule.rawValue: memory.rules.count,
            PersonalRecordKind.conversation.rawValue: conversations.count,
            PersonalRecordKind.message.rawValue: messages.count,
            PersonalRecordKind.styleProfile.rawValue: 1,
        ]
    }

    static func empty(bundleVersion: Int = 0) -> PersonalDataBundle {
        PersonalDataBundle(manifest: BackupManifest(bundleVersion: bundleVersion))
    }
}
