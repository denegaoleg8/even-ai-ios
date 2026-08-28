import CloudKit

/// The CloudKit representation of Personal AI storage — **adapter-only**.
///
/// No canonical Personal AI domain type references CloudKit. This file and its
/// siblings in `Infrastructure/PersonalAI/CloudKit/` are the sole `import
/// CloudKit` sites in the app target; `CKRecord` is a transport shape built
/// from a canonical record on the way out and discarded after decode on the
/// way in (see `CloudKitRecordMapper`).
///
/// Layout (approved in `PHASE2_CLOUDKIT_STEP1_PLAN.md`): two custom zones in
/// the **private** database.
/// - `PersonalAICore` — `Memory`, `Rule`, `StyleProfile` (small, restore-first)
/// - `PersonalAIChat` — `Conversation`, `Message` (append-heavy, restore-second)
///
/// `Revision` is deliberately **not** a v1 record type — revision history
/// stays local (and in local backup/export), exactly as the architecture
/// works today.
enum CloudKitSchema {

    static let containerIdentifier = "iCloud.com.evenai.app"

    // MARK: Zones

    enum Zone: String, CaseIterable, Sendable {
        case core
        case chat

        var zoneName: String {
            switch self {
            case .core: return "PersonalAICore"
            case .chat: return "PersonalAIChat"
            }
        }

        var zoneID: CKRecordZone.ID {
            CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        }

        static func containing(_ kind: PersonalRecordKind) -> Zone {
            switch kind {
            case .memory, .rule, .styleProfile: return .core
            case .conversation, .message: return .chat
            }
        }
    }

    static var allZoneIDs: [CKRecordZone.ID] { Zone.allCases.map(\.zoneID) }

    static func zoneID(for kind: PersonalRecordKind) -> CKRecordZone.ID {
        Zone.containing(kind).zoneID
    }

    // MARK: Record types

    enum RecordType {
        static let memory = "Memory"
        static let rule = "Rule"
        static let styleProfile = "StyleProfile"
        static let conversation = "Conversation"
        static let message = "Message"

        static func name(for kind: PersonalRecordKind) -> String {
            switch kind {
            case .memory: return memory
            case .rule: return rule
            case .styleProfile: return styleProfile
            case .conversation: return conversation
            case .message: return message
            }
        }

        static func kind(forRecordType type: String) -> PersonalRecordKind? {
            switch type {
            case memory: return .memory
            case rule: return .rule
            case styleProfile: return .styleProfile
            case conversation: return .conversation
            case message: return .message
            default: return nil
            }
        }
    }

    // MARK: Fields (one payload blob + minimal plaintext metadata)

    enum Field {
        /// The canonical entity JSON (`PersonalSyncCodec` output). Encrypted.
        static let payload = "payload"
        /// Tombstone marker mirroring the payload. Encrypted.
        static let deletedAt = "deletedAt"
        /// `PersonalRecordKind.rawValue`. Plaintext — a defensive type check,
        /// no memory content.
        static let recordKind = "recordKind"
        /// The entity's `updatedAt` / `timestamp`. Plaintext — a timestamp,
        /// no memory content.
        static let clientUpdatedAt = "clientUpdatedAt"
        /// `PersonalMemoryDocument.currentSchemaVersion` at write time.
        static let schemaVersion = "schemaVersion"
    }

    static let schemaVersion = Int64(PersonalMemoryDocument.currentSchemaVersion)
}

/// Deterministic `CKRecord.ID` derivation. The canonical Personal AI UUID is
/// the record name, verbatim — CloudKit never generates an identity the app
/// depends on, and the same canonical id always maps to the same record id.
enum CloudKitRecordID {

    static func make(kind: PersonalRecordKind, canonicalID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: canonicalID.uuidString, zoneID: CloudKitSchema.zoneID(for: kind))
    }

    /// The canonical UUID for a record id, or nil if the name is not a UUID.
    static func canonicalID(from recordID: CKRecord.ID) -> UUID? {
        UUID(uuidString: recordID.recordName)
    }

    /// A zone-qualified debug hint stored in `remoteID`. Nothing keys off it.
    static func qualifiedName(_ recordID: CKRecord.ID) -> String {
        "\(recordID.zoneID.zoneName):\(recordID.recordName)"
    }
}

/// The two-zone sync position, encoded into the opaque `SyncPullResult.cursor`
/// string. `PersonalAISyncEngine` only ever round-trips this — it never looks
/// inside. A garbage / partial / stale value is safe (the adapter falls back
/// to a full re-fetch of the affected zone).
struct CloudKitSyncCursor: Codable, Hashable, Sendable {
    var core: CloudKitZoneToken?
    var chat: CloudKitZoneToken?

    static let empty = CloudKitSyncCursor()

    func token(for zone: CloudKitSchema.Zone) -> CloudKitZoneToken? {
        zone == .core ? core : chat
    }

    func setting(_ zone: CloudKitSchema.Zone, _ token: CloudKitZoneToken?) -> CloudKitSyncCursor {
        var copy = self
        switch zone {
        case .core: copy.core = token
        case .chat: copy.chat = token
        }
        return copy
    }

    func encoded() -> String {
        (try? JSONEncoder().encode(self)).map { $0.base64EncodedString() } ?? ""
    }

    static func decode(_ string: String?) -> CloudKitSyncCursor? {
        guard let string, !string.isEmpty,
              let data = Data(base64Encoded: string),
              let cursor = try? JSONDecoder().decode(CloudKitSyncCursor.self, from: data)
        else { return nil }
        return cursor
    }
}
