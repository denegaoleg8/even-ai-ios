import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// `CKRecord.ID` must be a deterministic function of the canonical stable id —
/// CloudKit never generates an identity the app depends on.
@Suite("CloudKit: deterministic record IDs")
struct CloudKitRecordIDTests {

    @Test("same canonical id + kind always yields the same CKRecord.ID")
    func deterministic() {
        let id = UUID()
        for kind in PersonalRecordKind.allCases {
            let a = CloudKitRecordID.make(kind: kind, canonicalID: id)
            let b = CloudKitRecordID.make(kind: kind, canonicalID: id)
            #expect(a == b)
            #expect(a.recordName == id.uuidString)
        }
    }

    @Test("record name is the canonical UUID verbatim, for every entity kind")
    func verbatimUUID() {
        let memoryID = UUID(), ruleID = UUID(), convID = UUID(), msgID = UUID(), styleID = UUID()
        #expect(CloudKitRecordID.make(kind: .memory, canonicalID: memoryID).recordName == memoryID.uuidString)
        #expect(CloudKitRecordID.make(kind: .rule, canonicalID: ruleID).recordName == ruleID.uuidString)
        #expect(CloudKitRecordID.make(kind: .conversation, canonicalID: convID).recordName == convID.uuidString)
        #expect(CloudKitRecordID.make(kind: .message, canonicalID: msgID).recordName == msgID.uuidString)
        #expect(CloudKitRecordID.make(kind: .styleProfile, canonicalID: styleID).recordName == styleID.uuidString)
    }

    @Test("canonical id round-trips out of a record id")
    func canonicalIDRoundTrip() {
        let id = UUID()
        let recordID = CloudKitRecordID.make(kind: .message, canonicalID: id)
        #expect(CloudKitRecordID.canonicalID(from: recordID) == id)
    }

    @Test("core kinds land in PersonalAICore, chat kinds in PersonalAIChat")
    func zonePlacement() {
        #expect(CloudKitRecordID.make(kind: .memory, canonicalID: UUID()).zoneID.zoneName == "PersonalAICore")
        #expect(CloudKitRecordID.make(kind: .rule, canonicalID: UUID()).zoneID.zoneName == "PersonalAICore")
        #expect(CloudKitRecordID.make(kind: .styleProfile, canonicalID: UUID()).zoneID.zoneName == "PersonalAICore")
        #expect(CloudKitRecordID.make(kind: .conversation, canonicalID: UUID()).zoneID.zoneName == "PersonalAIChat")
        #expect(CloudKitRecordID.make(kind: .message, canonicalID: UUID()).zoneID.zoneName == "PersonalAIChat")
    }

    @Test("different canonical ids never collide")
    func distinctIDsDistinctNames() {
        var names = Set<String>()
        for _ in 0..<500 {
            names.insert(CloudKitRecordID.make(kind: .memory, canonicalID: UUID()).recordName)
        }
        #expect(names.count == 500)
    }

    @Test("cross-kind: the plaintext recordKind field disambiguates, and a mismatch is rejected")
    func crossKindGuard() {
        // A memory and a rule are independently generated UUIDs and will not
        // collide in practice; if a record's type and its recordKind field
        // ever disagreed, the mapper rejects it.
        let memory = MemoryRecord(category: .knowledge, canonicalContent: "x")
        let record = CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(memory))
        #expect(record.recordType == "Memory")
        #expect(record[CloudKitSchema.Field.recordKind] as? String == "memory")
        record[CloudKitSchema.Field.recordKind] = "conversation"
        #expect(CloudKitRecordMapper.makeEnvelope(from: record, syntheticRevision: 0) == nil)
    }

    @Test("style profile deterministic id is stable per owner")
    func styleProfileStableID() {
        let a = SyncableStyleProfile.stableID(ownerID: "user-A")
        let b = SyncableStyleProfile.stableID(ownerID: "user-A")
        let c = SyncableStyleProfile.stableID(ownerID: "user-B")
        #expect(a == b)
        #expect(a != c)
        #expect(CloudKitRecordID.make(kind: .styleProfile, canonicalID: a).recordName == a.uuidString)
    }
}
