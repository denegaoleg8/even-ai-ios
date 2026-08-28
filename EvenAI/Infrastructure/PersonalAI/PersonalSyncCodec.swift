import Foundation

/// Encodes / decodes the one wire shape (`SyncRecordEnvelope`) for every
/// record kind, so `PersonalAISyncEngine`, `LocalPersonalDataStore`, the
/// mock backend, and the exporter all agree on exactly one serialization.
enum PersonalSyncCodec {

    /// A syncable record decoded back out of an envelope.
    enum Decoded: Sendable {
        case memory(MemoryRecord)
        case rule(Rule)
        case conversation(PersonalAIConversation)
        case message(PersonalAIChatMessage)
        case styleProfile(SyncableStyleProfile)

        var id: UUID {
            switch self {
            case .memory(let r): return r.id
            case .rule(let r): return r.id
            case .conversation(let c): return c.id
            case .message(let m): return m.id
            case .styleProfile(let s): return s.id
            }
        }
        var kind: PersonalRecordKind {
            switch self {
            case .memory: return .memory
            case .rule: return .rule
            case .conversation: return .conversation
            case .message: return .message
            case .styleProfile: return .styleProfile
            }
        }

        var revision: Int {
            switch self {
            case .memory(let r): return r.revision
            case .rule(let r): return r.revision
            case .conversation(let c): return c.revision
            case .message(let m): return m.revision
            case .styleProfile(let s): return s.revision
            }
        }

        /// The record serialized back to JSON — for a `RecordRevision`.
        var payloadJSON: String {
            let data: Data?
            switch self {
            case .memory(let r): data = try? JSONEncoder.personalAI.encode(r)
            case .rule(let r): data = try? JSONEncoder.personalAI.encode(r)
            case .conversation(let c): data = try? JSONEncoder.personalAI.encode(c)
            case .message(let m): data = try? JSONEncoder.personalAI.encode(m)
            case .styleProfile(let s): data = try? JSONEncoder.personalAI.encode(s)
            }
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// `baseRevision` must be the **last server revision** the caller synced
    /// for this record (0 if never), *not* the record's local `revision`.
    static func encode<T: PersonalCloudSyncable>(_ record: T, baseRevision: Int = 0) -> SyncRecordEnvelope {
        let json = (try? JSONEncoder.personalAI.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return SyncRecordEnvelope(
            kind: T.recordKind,
            id: record.id,
            remoteID: record.remoteID,
            baseRevision: baseRevision,
            payloadJSON: json,
            deletedAt: record.deletedAt
        )
    }

    static func decode(_ envelope: SyncRecordEnvelope) -> Decoded? {
        guard let data = envelope.payloadJSON.data(using: .utf8) else { return nil }
        let d = JSONDecoder.personalAI
        switch envelope.kind {
        case .memory: return (try? d.decode(MemoryRecord.self, from: data)).map(Decoded.memory)
        case .rule: return (try? d.decode(Rule.self, from: data)).map(Decoded.rule)
        case .conversation: return (try? d.decode(PersonalAIConversation.self, from: data)).map(Decoded.conversation)
        case .message: return (try? d.decode(PersonalAIChatMessage.self, from: data)).map(Decoded.message)
        case .styleProfile: return (try? d.decode(SyncableStyleProfile.self, from: data)).map(Decoded.styleProfile)
        }
    }
}

/// The style profile as a syncable record — it is a per-user singleton, so
/// its `id` is deterministic (derived from `ownerID`) and there is exactly
/// one per user.
struct SyncableStyleProfile: PersonalCloudSyncable, Hashable {
    static var recordKind: PersonalRecordKind { .styleProfile }

    let id: UUID
    var profile: PersonalAIStyleProfile
    var remoteID: String?
    var revision: Int
    var syncState: MemorySyncState
    var deletedAt: Date?
    var ownerID: String?
    var updatedAt: Date

    init(profile: PersonalAIStyleProfile, ownerID: String?, revision: Int = 0, syncState: MemorySyncState = .localOnly, remoteID: String? = nil) {
        self.id = Self.stableID(ownerID: ownerID)
        self.profile = profile
        self.ownerID = ownerID
        self.revision = revision
        self.syncState = syncState
        self.remoteID = remoteID
        self.deletedAt = nil
        self.updatedAt = profile.updatedAt
    }

    /// One deterministic id per owner so the singleton always collides with
    /// itself on the server (`nil` owner → a fixed local id).
    static func stableID(ownerID: String?) -> UUID {
        guard let ownerID, let ns = UUID(uuidString: "9F1B8E1C-0000-4000-8000-000000000001") else {
            return UUID(uuidString: "9F1B8E1C-0000-4000-8000-0000000000FF")!
        }
        // Simple, stable derivation — not cryptographic, just needs to be
        // reproducible for a given owner string.
        var hasher = Hasher()
        hasher.combine(ns)
        hasher.combine(ownerID)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = withUnsafeBytes(of: h.bigEndian) { Array($0) }
        bytes += Array("EVENAI-STYLE".utf8.prefix(8))
        let uuidBytes = (0..<16).map { bytes[$0 % bytes.count] }
        return NSUUID(uuidBytes: uuidBytes) as UUID
    }
}

/// Rebuilds a `PersonalDataBundle` from a flat list of envelopes (a cloud
/// snapshot).
enum PersonalBundleAssembler {
    static func assemble(from envelopes: [SyncRecordEnvelope], bundleVersion: Int, ownerID: String? = nil) -> PersonalDataBundle {
        var records: [MemoryRecord] = []
        var rules: [Rule] = []
        var conversations: [PersonalAIConversation] = []
        var messages: [PersonalAIChatMessage] = []
        var style = PersonalAIStyleProfile.empty

        for envelope in envelopes {
            guard let decoded = PersonalSyncCodec.decode(envelope) else { continue }
            switch decoded {
            case .memory(let r): records.append(r)
            case .rule(let r): rules.append(r)
            case .conversation(let c): conversations.append(c)
            case .message(let m): messages.append(m)
            case .styleProfile(let s): style = s.profile
            }
        }

        var memoryDoc = PersonalMemoryDocument(records: records, rules: rules, styleProfile: style)
        memoryDoc.doNotRememberConversationIDs = Set(conversations.filter { $0.doNotRemember }.map { $0.id })

        var bundle = PersonalDataBundle(
            manifest: BackupManifest(bundleVersion: bundleVersion, ownerID: ownerID),
            memory: memoryDoc,
            conversations: conversations,
            messages: messages,
            revisions: []
        )
        bundle.manifest.counts = bundle.recordCounts
        bundle.manifest.checksum = PersonalBundleChecksum.compute(for: bundle)
        return bundle
    }
}
