import CloudKit

/// Canonical Personal AI  ⇄  `CKRecord`. **The one and only translation
/// point.** `CKRecord` is never the source of truth: it is constructed from a
/// wire envelope on the way out and thrown away after decode on the way in.
///
/// Record-per-canonical-entity: one `CKRecord` per memory / rule / conversation
/// / message, plus the style-profile singleton. The entity's full JSON goes in
/// one encrypted `payload` field; only kind/timestamp/schema metadata is
/// plaintext. A corrupt `payload` can damage exactly one entity.
enum CloudKitRecordMapper {

    // MARK: Envelope → CKRecord (push)

    static func makeRecord(from envelope: SyncRecordEnvelope, systemFieldsArchive: Data? = nil) -> CKRecord {
        let record: CKRecord
        if let systemFieldsArchive,
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFieldsArchive) {
            unarchiver.requiresSecureCoding = true
            record = CKRecord(coder: unarchiver) ?? freshRecord(for: envelope)
            unarchiver.finishDecoding()
        } else {
            record = freshRecord(for: envelope)
        }

        record.encryptedValues[CloudKitSchema.Field.payload] = Data(envelope.payloadJSON.utf8)
        if let deletedAt = envelope.deletedAt {
            record.encryptedValues[CloudKitSchema.Field.deletedAt] = deletedAt as NSDate
        } else {
            record[CloudKitSchema.Field.deletedAt] = nil
        }
        record[CloudKitSchema.Field.recordKind] = envelope.kind.rawValue
        record[CloudKitSchema.Field.clientUpdatedAt] = updatedAt(of: envelope) as NSDate
        record[CloudKitSchema.Field.schemaVersion] = CloudKitSchema.schemaVersion
        return record
    }

    private static func freshRecord(for envelope: SyncRecordEnvelope) -> CKRecord {
        CKRecord(
            recordType: CloudKitSchema.RecordType.name(for: envelope.kind),
            recordID: CloudKitRecordID.make(kind: envelope.kind, canonicalID: envelope.id)
        )
    }

    // MARK: CKRecord → Envelope (pull)

    /// Decode a fetched record into a wire envelope. Returns `nil` when a
    /// required field is missing or malformed — the caller treats that as a
    /// decode failure and does **not** advance the cursor or touch local data.
    static func makeEnvelope(from record: CKRecord, syntheticRevision: Int) -> SyncRecordEnvelope? {
        guard let kind = CloudKitSchema.RecordType.kind(forRecordType: record.recordType) else { return nil }
        // The plaintext kind field must agree with the record type — guards
        // against type confusion even if two canonical UUIDs ever collided.
        if let kindField = record[CloudKitSchema.Field.recordKind] as? String, kindField != kind.rawValue {
            return nil
        }
        guard let canonicalID = CloudKitRecordID.canonicalID(from: record.recordID) else { return nil }
        guard let payloadData = record.encryptedValues[CloudKitSchema.Field.payload] as? Data,
              let payloadJSON = String(data: payloadData, encoding: .utf8),
              !payloadJSON.isEmpty
        else { return nil }

        let deletedAt = (record.encryptedValues[CloudKitSchema.Field.deletedAt] as? Date)

        return SyncRecordEnvelope(
            kind: kind,
            id: canonicalID,
            remoteID: CloudKitRecordID.qualifiedName(record.recordID),
            baseRevision: syntheticRevision,
            payloadJSON: payloadJSON,
            deletedAt: deletedAt,
            serverRevision: syntheticRevision
        )
    }

    /// A server-side deletion notification → a tombstone envelope. The engine
    /// converts this to a local soft tombstone and never resurrects it.
    static func makeTombstoneEnvelope(recordName: String, recordType: String, syntheticRevision: Int, now: Date = .now) -> SyncRecordEnvelope? {
        guard let kind = CloudKitSchema.RecordType.kind(forRecordType: recordType),
              let id = UUID(uuidString: recordName)
        else { return nil }
        return SyncRecordEnvelope(
            kind: kind,
            id: id,
            remoteID: nil,
            baseRevision: syntheticRevision,
            payloadJSON: "",
            deletedAt: now,
            serverRevision: syntheticRevision
        )
    }

    // MARK: Helpers

    static func archiveSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func updatedAt(of envelope: SyncRecordEnvelope) -> Date {
        guard let data = envelope.payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Date() }
        let iso = ISO8601DateFormatter()
        for key in ["updatedAt", "timestamp", "changedAt"] {
            if let string = object[key] as? String, let date = iso.date(from: string) { return date }
        }
        return Date()
    }
}

// MARK: - Domain-level convenience (tests / restore assembly)

extension CloudKitRecordMapper {

    static func makeRecord<T: PersonalCloudSyncable>(_ value: T, baseRevision: Int = 0) -> CKRecord {
        makeRecord(from: PersonalSyncCodec.encode(value, baseRevision: baseRevision))
    }

    static func decode(_ record: CKRecord) -> PersonalSyncCodec.Decoded? {
        guard let envelope = makeEnvelope(from: record, syntheticRevision: 0) else { return nil }
        return PersonalSyncCodec.decode(envelope)
    }
}
