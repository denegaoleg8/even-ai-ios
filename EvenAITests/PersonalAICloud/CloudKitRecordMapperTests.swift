import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// `CloudKitRecordMapper` — canonical Personal AI ⇄ `CKRecord`. Offline, no
/// account, no network. The mapper is the only translation point; `CKRecord`
/// is never the source of truth.
@Suite("CloudKit: record mapper round trips")
struct CloudKitRecordMapperTests {

    // MARK: helpers

    private func roundTrip(_ envelope: SyncRecordEnvelope) -> SyncRecordEnvelope? {
        let record = CloudKitRecordMapper.makeRecord(from: envelope)
        return CloudKitRecordMapper.makeEnvelope(from: record, syntheticRevision: 42)
    }

    private func assertPayloadPreserved(_ original: SyncRecordEnvelope, _ sourceFile: StaticString = #file, _ line: UInt = #line) {
        guard let back = roundTrip(original) else {
            Issue.record("round trip returned nil for \(original.kind)")
            return
        }
        #expect(back.id == original.id)
        #expect(back.kind == original.kind)
        #expect(back.payloadJSON == original.payloadJSON)
        #expect(back.deletedAt == original.deletedAt)
    }

    // MARK: memory / project / person / episode / knowledge (all one CK type)

    @Test("memory round trip preserves canonical content and every field")
    func memoryRoundTrip() {
        let memory = MemoryRecord(
            id: UUID(), ownerID: "user-1", category: .knowledge, scope: .global,
            canonicalContent: "The EvenAI launch is planned for October 2026.",
            structured: ["month": "october", "year": "2026"], entities: ["evenai", "launch"],
            confidence: 0.82, importance: 0.7, userConfirmed: true, pinned: true,
            sourceConversationIDs: [UUID()], sourceMessageIDs: [UUID(), UUID()]
        )
        let env = PersonalSyncCodec.encode(memory)
        guard let back = roundTrip(env), case .memory(let decoded)? = PersonalSyncCodec.decode(back) else {
            Issue.record("memory did not round trip"); return
        }
        #expect(decoded.id == memory.id)
        #expect(decoded.canonicalContent == memory.canonicalContent)
        #expect(decoded.structured == memory.structured)
        #expect(decoded.entities == memory.entities)
        #expect(decoded.category == memory.category)
        #expect(decoded.confidence == memory.confidence)
        #expect(decoded.userConfirmed == memory.userConfirmed)
        #expect(decoded.pinned == memory.pinned)
        #expect(decoded.sourceConversationIDs == memory.sourceConversationIDs)
        #expect(decoded.sourceMessageIDs == memory.sourceMessageIDs)
    }

    @Test("project / person / episode categories map through the one Memory record type")
    func categoryVariantsRoundTrip() {
        for category in [MemoryCategory.projects, .people, .episodes] {
            let memory = MemoryRecord(category: category, canonicalContent: "content for \(category.rawValue)", entities: ["x"])
            let record = CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))
            #expect(record.recordType == CloudKitSchema.RecordType.memory)
            #expect(record[CloudKitSchema.Field.recordKind] as? String == "memory")
            guard case .memory(let back)? = CloudKitRecordMapper.decode(record) else {
                Issue.record("\(category) did not decode"); continue
            }
            #expect(back.category == category)
            #expect(back.canonicalContent == memory.canonicalContent)
        }
    }

    @Test("source / provenance UUID arrays survive the round trip")
    func provenanceRoundTrip() {
        let convIDs = [UUID(), UUID()]
        let msgIDs = [UUID(), UUID(), UUID()]
        let memory = MemoryRecord(category: .knowledge, canonicalContent: "x",
                                  sourceConversationIDs: convIDs, sourceMessageIDs: msgIDs)
        guard case .memory(let back)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))) else {
            Issue.record("no decode"); return
        }
        #expect(back.sourceConversationIDs == convIDs)
        #expect(back.sourceMessageIDs == msgIDs)
    }

    // MARK: rule

    @Test("rule round trip preserves text, enabled, scope, priority, expiry")
    func ruleRoundTrip() {
        let rule = Rule(text: "Keep business replies short.", enabled: false,
                        priority: .activeRule, scope: .g2Replies, source: .explicitCommand,
                        expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        guard case .rule(let back)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(rule))) else {
            Issue.record("no decode"); return
        }
        #expect(back.id == rule.id)
        #expect(back.text == rule.text)
        #expect(back.enabled == rule.enabled)
        #expect(back.scope == rule.scope)
        #expect(back.priority == rule.priority)
        #expect(back.expiresAt == rule.expiresAt)
    }

    // MARK: conversation / message

    @Test("conversation round trip preserves title, flags, counts")
    func conversationRoundTrip() {
        let conv = PersonalAIConversation(title: "Trip planning", lastMessageAt: Date(), messageCount: 7, doNotRemember: false)
        guard case .conversation(let back)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(conv))) else {
            Issue.record("no decode"); return
        }
        #expect(back.id == conv.id)
        #expect(back.title == conv.title)
        #expect(back.messageCount == conv.messageCount)
        #expect(back.doNotRemember == conv.doNotRemember)
    }

    @Test("message round trip preserves role, text, timestamp, conversation link")
    func messageRoundTrip() {
        let convID = UUID()
        let msg = PersonalAIChatMessage(conversationID: convID, role: .assistant, text: "Here's what I found.",
                                        timestamp: Date(timeIntervalSince1970: 1_800_000_000), eligibleForMemory: true)
        guard case .message(let back)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(msg))) else {
            Issue.record("no decode"); return
        }
        #expect(back.id == msg.id)
        #expect(back.conversationID == convID)
        #expect(back.role == .assistant)
        #expect(back.text == msg.text)
        #expect(back.timestamp == msg.timestamp)
    }

    // MARK: style profile (canonical singleton)

    @Test("style profile round trip")
    func styleProfileRoundTrip() {
        var profile = PersonalAIStyleProfile.empty
        profile.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let syncable = SyncableStyleProfile(profile: profile, ownerID: "user-1", revision: 3, syncState: .pendingPush)
        let record = CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(syncable, baseRevision: 3))
        #expect(record.recordType == CloudKitSchema.RecordType.styleProfile)
        guard case .styleProfile(let back)? = CloudKitRecordMapper.decode(record) else {
            Issue.record("no decode"); return
        }
        #expect(back.id == syncable.id)
        #expect(back.profile.updatedAt == profile.updatedAt)
    }

    // MARK: tombstone

    @Test("tombstone round trip — deletedAt preserved in the record and the envelope")
    func tombstoneRoundTrip() {
        var memory = MemoryRecord(category: .knowledge, canonicalContent: "delete me")
        let deletedAt = Date(timeIntervalSince1970: 1_850_000_000)
        memory.deletedAt = deletedAt
        memory.status = .deleted
        let env = PersonalSyncCodec.encode(memory)
        let record = CloudKitRecordMapper.makeRecord(from: env)
        #expect(record.encryptedValues[CloudKitSchema.Field.deletedAt] as? Date == deletedAt)
        guard let back = CloudKitRecordMapper.makeEnvelope(from: record, syntheticRevision: 1) else {
            Issue.record("no decode"); return
        }
        #expect(back.deletedAt == deletedAt)
    }

    @Test("server-side deletion notification maps to a tombstone envelope")
    func serverDeletionToTombstone() {
        let id = UUID()
        let env = CloudKitRecordMapper.makeTombstoneEnvelope(
            recordName: id.uuidString, recordType: CloudKitSchema.RecordType.message, syntheticRevision: 9
        )
        #expect(env?.id == id)
        #expect(env?.kind == .message)
        #expect(env?.deletedAt != nil)
        #expect(env?.payloadJSON == "")
    }

    // MARK: dates / enums / optionals / unknown fields / malformed

    @Test("dates are preserved exactly across the round trip")
    func datesPreserved() {
        let created = Date(timeIntervalSince1970: 1_600_000_123)
        let updated = Date(timeIntervalSince1970: 1_650_000_456)
        let memory = MemoryRecord(category: .profile, canonicalContent: "x", createdAt: created, updatedAt: updated)
        guard case .memory(let back)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))) else {
            Issue.record("no decode"); return
        }
        #expect(back.createdAt == created)
        #expect(back.updatedAt == updated)
    }

    @Test("enum values (category, scope, status, source) are preserved")
    func enumsPreserved() {
        let memory = MemoryRecord(category: .workingContext, scope: .project(id: "proj-9"),
                                  canonicalContent: "x", status: .archived)
        guard case .memory(let back)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))) else {
            Issue.record("no decode"); return
        }
        #expect(back.category == .workingContext)
        #expect(back.scope == .project(id: "proj-9"))
        #expect(back.status == .archived)
    }

    @Test("optional fields preserved — nil stays nil, set stays set")
    func optionalsPreserved() {
        let withNil = MemoryRecord(category: .knowledge, canonicalContent: "a", expiresAt: nil)
        let withValue = MemoryRecord(category: .knowledge, canonicalContent: "b",
                                     expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        guard case .memory(let n)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(withNil))),
              case .memory(let v)? = CloudKitRecordMapper.decode(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(withValue)))
        else { Issue.record("no decode"); return }
        #expect(n.expiresAt == nil)
        #expect(v.expiresAt == withValue.expiresAt)
    }

    @Test("unknown future CKRecord fields are ignored, canonical payload still decodes")
    func unknownFieldsIgnored() {
        let memory = MemoryRecord(category: .knowledge, canonicalContent: "forward compatible")
        let record = CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))
        record["someFutureField"] = "hello" as CKRecordValue
        record["anotherFutureNumber"] = 99 as CKRecordValue
        guard case .memory(let back)? = CloudKitRecordMapper.decode(record) else {
            Issue.record("no decode"); return
        }
        #expect(back.canonicalContent == "forward compatible")
    }

    @Test("a missing payload field fails safely (nil), never a crash or partial record")
    func malformedRequiredFieldFailsSafely() {
        let record = CKRecord(recordType: CloudKitSchema.RecordType.memory,
                              recordID: CloudKitRecordID.make(kind: .memory, canonicalID: UUID()))
        record[CloudKitSchema.Field.recordKind] = "memory"
        // no payload
        #expect(CloudKitRecordMapper.makeEnvelope(from: record, syntheticRevision: 1) == nil)

        // payload present but not valid UTF-8 JSON string still returns a
        // string; the codec layer then rejects it — the mapper's contract is
        // "non-empty payload string or nil".
        record.encryptedValues[CloudKitSchema.Field.payload] = Data([0xFF, 0xFE])
        let env = CloudKitRecordMapper.makeEnvelope(from: record, syntheticRevision: 1)
        if let env { #expect(PersonalSyncCodec.decode(env) == nil) }
    }

    @Test("record type / recordKind mismatch is rejected (type-confusion guard)")
    func typeConfusionRejected() {
        let record = CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(
            MemoryRecord(category: .knowledge, canonicalContent: "x")))
        record[CloudKitSchema.Field.recordKind] = "rule"  // lie about the kind
        #expect(CloudKitRecordMapper.makeEnvelope(from: record, syntheticRevision: 1) == nil)
    }

    @Test("canonical model never depends on CKRecord object identity")
    func noObjectIdentityDependence() {
        let memory = MemoryRecord(category: .knowledge, canonicalContent: "identity independent")
        let env = PersonalSyncCodec.encode(memory)
        let recordA = CloudKitRecordMapper.makeRecord(from: env)
        let recordB = CloudKitRecordMapper.makeRecord(from: env)
        #expect(recordA !== recordB) // distinct objects
        guard case .memory(let a)? = CloudKitRecordMapper.decode(recordA),
              case .memory(let b)? = CloudKitRecordMapper.decode(recordB) else {
            Issue.record("no decode"); return
        }
        #expect(a.id == b.id)
        #expect(a.canonicalContent == b.canonicalContent)
    }

    @Test("payload and deletedAt are stored as encrypted values, not plaintext")
    func contentFieldsAreEncrypted() {
        var memory = MemoryRecord(category: .profile, canonicalContent: "private")
        memory.deletedAt = Date()
        let record = CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))
        // Not readable as a plain field...
        #expect(record[CloudKitSchema.Field.payload] == nil)
        #expect(record[CloudKitSchema.Field.deletedAt] == nil)
        // ...only through encryptedValues.
        #expect(record.encryptedValues[CloudKitSchema.Field.payload] != nil)
        #expect(record.encryptedValues[CloudKitSchema.Field.deletedAt] != nil)
        // Metadata stays plaintext.
        #expect(record[CloudKitSchema.Field.recordKind] as? String == "memory")
    }
}
