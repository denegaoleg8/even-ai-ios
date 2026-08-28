import Foundation

/// One facade over everything the sync engine, exporter and backup
/// coordinator touch: the memory store, the conversation store, the
/// revision log and the sync-state record. It owns no storage itself — it
/// delegates to the two Phase 1 stores (which now also persist revisions and
/// sync state).
///
/// `ownerID` is stamped onto records as they are pushed so the server can
/// file them. Do-Not-Remember conversations and their messages are excluded
/// from `pendingChanges()` and `exportBundle()` — they never leave the
/// device.
actor LocalPersonalDataStore: PersonalDataStore {

    private let memory: any PersonalMemoryStore
    private let conversations: any PersonalAIConversationStore
    private let ownerIDProvider: @Sendable () -> String?
    private let merger: MemoryMerger

    init(
        memory: any PersonalMemoryStore,
        conversations: any PersonalAIConversationStore,
        ownerID: @escaping @Sendable () -> String? = { nil },
        merger: MemoryMerger = MemoryMerger()
    ) {
        self.memory = memory
        self.conversations = conversations
        self.ownerIDProvider = ownerID
        self.merger = merger
    }

    // MARK: - Bundle export / import

    func exportBundle(selection: ExportSelection, bundleVersion: Int) async -> PersonalDataBundle {
        let doc = await memory.export()
        let convs = await conversations.allConversations()
        let msgs = await conversations.allMessages()
        return PersonalDataExporter.makeBundle(
            memory: doc,
            conversations: convs,
            messages: msgs,
            selection: selection,
            bundleVersion: bundleVersion,
            ownerID: ownerIDProvider()
        )
    }

    func importBundle(_ bundle: PersonalDataBundle, strategy: ImportStrategy) async -> ImportResult {
        await PersonalDataImporter.restore(
            bundle,
            into: memory,
            conversationStore: conversations,
            strategy: strategy,
            merger: merger
        )
    }

    // MARK: - Sync change feed

    func pendingChanges() async -> [SyncRecordEnvelope] {
        let owner = ownerIDProvider()
        let syncState = await memory.loadSyncState()
        var envelopes: [SyncRecordEnvelope] = []

        func base(_ kind: PersonalRecordKind, _ id: UUID) -> Int {
            syncState.syncedRevisions[PersonalSyncState.revisionKey(kind, id)] ?? 0
        }

        let excludedConversationIDs = Set(
            (await conversations.allConversations()).filter { $0.doNotRemember }.map { $0.id }
        ).union(await memory.excludedConversationIDs())

        for var record in await memory.allMemories() where record.hasPendingPush {
            record.ownerID = record.ownerID ?? owner
            envelopes.append(PersonalSyncCodec.encode(record, baseRevision: base(.memory, record.id)))
        }
        for var rule in await memory.allRules() where rule.hasPendingPush {
            rule.ownerID = rule.ownerID ?? owner
            envelopes.append(PersonalSyncCodec.encode(rule, baseRevision: base(.rule, rule.id)))
        }
        for var conv in await conversations.allConversations()
        where conv.hasPendingPush && !conv.doNotRemember {
            conv.ownerID = conv.ownerID ?? owner
            envelopes.append(PersonalSyncCodec.encode(conv, baseRevision: base(.conversation, conv.id)))
        }
        for var message in await conversations.allMessages()
        where message.hasPendingPush && !excludedConversationIDs.contains(message.conversationID) {
            message.ownerID = message.ownerID ?? owner
            envelopes.append(PersonalSyncCodec.encode(message, baseRevision: base(.message, message.id)))
        }

        // Style profile — a singleton; pending if it changed since last sync.
        let style = await memory.styleProfile()
        if syncState.lastSyncedStyleUpdatedAt == nil || style.updatedAt > syncState.lastSyncedStyleUpdatedAt! {
            if style.hasSignal || syncState.styleRevision > 0 {
                let syncable = SyncableStyleProfile(
                    profile: style, ownerID: owner,
                    revision: syncState.styleRevision, syncState: .pendingPush,
                    remoteID: syncState.styleRemoteID
                )
                envelopes.append(PersonalSyncCodec.encode(syncable, baseRevision: syncState.styleRevision))
            }
        }

        return envelopes
    }

    // MARK: - Apply server records

    func applyRemote(_ envelopes: [SyncRecordEnvelope], asConflictResolution: Bool) async -> [RecordRevision] {
        var revisions: [RecordRevision] = []
        var memoriesToUpsert: [MemoryRecord] = []
        var rulesToUpsert: [Rule] = []
        var conversationsToUpsert: [PersonalAIConversation] = []
        var messagesToUpsert: [PersonalAIChatMessage] = []

        let localMemories = Dictionary(uniqueKeysWithValues: (await memory.allMemories()).map { ($0.id, $0) })
        let localRules = Dictionary(uniqueKeysWithValues: (await memory.allRules()).map { ($0.id, $0) })
        let localConvs = Dictionary(uniqueKeysWithValues: (await conversations.allConversations()).map { ($0.id, $0) })
        let localMessages = Dictionary(uniqueKeysWithValues: (await conversations.allMessages()).map { ($0.id, $0) })
        var syncState = await memory.loadSyncState()

        // A conflict-resolved record is re-pushed so the server becomes
        // authoritative; a plain pull just fast-forwards to `.synced`.
        let appliedState: MemorySyncState = asConflictResolution ? .pendingPush : .synced

        for envelope in envelopes {
            guard let decoded = PersonalSyncCodec.decode(envelope) else { continue }
            let serverRev = envelope.serverRevision ?? decoded.revision
            let key = PersonalSyncState.revisionKey(envelope.kind, envelope.id)
            let alreadyApplied = (syncState.syncedRevisions[key] ?? -1) >= serverRev
            if envelope.kind != .styleProfile {
                syncState.syncedRevisions[key] = max(serverRev, syncState.syncedRevisions[key] ?? 0)
            }
            switch decoded {
            case .memory(var incoming):
                incoming.remoteID = envelope.remoteID
                if let local = localMemories[incoming.id] {
                    if local.hasPendingPush && !asConflictResolution { continue }
                    if alreadyApplied && incoming.deletedAt == nil && !asConflictResolution { continue }
                    revisions.append(makeRevision(local, kind: .memory, reason: asConflictResolution ? "sync:conflict-resolution" : "sync:pull-fast-forward"))
                }
                incoming.syncState = appliedState
                if incoming.deletedAt != nil { incoming.status = .deleted; incoming.enabled = false; incoming.syncState = .synced }
                memoriesToUpsert.append(incoming)

            case .rule(var incoming):
                incoming.remoteID = envelope.remoteID
                if let local = localRules[incoming.id] {
                    if local.hasPendingPush && !asConflictResolution { continue }
                    if alreadyApplied && incoming.deletedAt == nil && !asConflictResolution { continue }
                    revisions.append(makeRevision(local, kind: .rule, reason: asConflictResolution ? "sync:conflict-resolution" : "sync:pull-fast-forward"))
                }
                incoming.syncState = appliedState
                rulesToUpsert.append(incoming)

            case .conversation(var incoming):
                incoming.remoteID = envelope.remoteID
                if let local = localConvs[incoming.id], local.hasPendingPush, !asConflictResolution { continue }
                incoming.syncState = appliedState
                conversationsToUpsert.append(incoming)

            case .message(var incoming):
                incoming.remoteID = envelope.remoteID
                if localMessages[incoming.id] != nil, incoming.deletedAt == nil, !asConflictResolution { continue } // append-only, already have it
                incoming.syncState = .synced
                messagesToUpsert.append(incoming)

            case .styleProfile(let incoming):
                let serverRev = envelope.serverRevision ?? incoming.revision
                if serverRev > syncState.styleRevision || asConflictResolution {
                    let localStyle = await memory.styleProfile()
                    let localUnchanged = !localStyle.hasSignal || localStyle.updatedAt <= (syncState.lastSyncedStyleUpdatedAt ?? .distantPast)
                    if localUnchanged || asConflictResolution {
                        await memory.updateStyleProfile(incoming.profile)
                        syncState.styleRevision = serverRev
                        syncState.styleRemoteID = envelope.remoteID
                        syncState.lastSyncedStyleUpdatedAt = incoming.profile.updatedAt
                    }
                }
            }
        }

        if !memoriesToUpsert.isEmpty { await memory.upsert(memoriesToUpsert) }
        for rule in rulesToUpsert { await memory.upsertRule(rule) }
        for conv in conversationsToUpsert { await conversations.upsertConversation(conv) }
        if !messagesToUpsert.isEmpty { await conversations.upsertMessages(messagesToUpsert) }
        for revision in revisions { await memory.appendRevision(revision) }
        await memory.saveSyncState(syncState)

        return revisions
    }

    // MARK: - Mark accepted records synced

    func markSynced(_ accepted: [SyncRecordEnvelope]) async {
        var memoriesToUpsert: [MemoryRecord] = []
        var rulesToUpsert: [Rule] = []
        var conversationsToUpsert: [PersonalAIConversation] = []
        var messagesToUpsert: [PersonalAIChatMessage] = []
        var syncState = await memory.loadSyncState()

        let localMemories = Dictionary(uniqueKeysWithValues: (await memory.allMemories()).map { ($0.id, $0) })
        let localRules = Dictionary(uniqueKeysWithValues: (await memory.allRules()).map { ($0.id, $0) })
        let localConvs = Dictionary(uniqueKeysWithValues: (await conversations.allConversations()).map { ($0.id, $0) })
        let localMessages = Dictionary(uniqueKeysWithValues: (await conversations.allMessages()).map { ($0.id, $0) })

        for envelope in accepted {
            let serverRev = envelope.serverRevision ?? 0
            if envelope.kind != .styleProfile {
                syncState.syncedRevisions[PersonalSyncState.revisionKey(envelope.kind, envelope.id)] = serverRev
            }
            switch envelope.kind {
            case .memory:
                guard var local = localMemories[envelope.id] else { break }
                local.remoteID = envelope.remoteID
                local.syncState = .synced
                if envelope.deletedAt != nil { local.deletedAt = envelope.deletedAt; local.status = .deleted; local.enabled = false }
                memoriesToUpsert.append(local)
            case .rule:
                guard var local = localRules[envelope.id] else { break }
                local.remoteID = envelope.remoteID
                local.syncState = .synced
                rulesToUpsert.append(local)
            case .conversation:
                guard var local = localConvs[envelope.id] else { break }
                local.remoteID = envelope.remoteID
                local.syncState = .synced
                conversationsToUpsert.append(local)
            case .message:
                guard var local = localMessages[envelope.id] else { break }
                local.remoteID = envelope.remoteID
                local.syncState = .synced
                messagesToUpsert.append(local)
            case .styleProfile:
                syncState.styleRevision = serverRev
                syncState.styleRemoteID = envelope.remoteID
                syncState.lastSyncedStyleUpdatedAt = (await memory.styleProfile()).updatedAt
            }
        }

        if !memoriesToUpsert.isEmpty { await memory.upsert(memoriesToUpsert) }
        for rule in rulesToUpsert { await memory.upsertRule(rule) }
        for conv in conversationsToUpsert { await conversations.upsertConversation(conv) }
        if !messagesToUpsert.isEmpty { await conversations.upsertMessages(messagesToUpsert) }
        await memory.saveSyncState(syncState)
    }

    // MARK: - Sync state & revisions

    func syncState() async -> PersonalSyncState { await memory.loadSyncState() }

    func updateSyncState(_ mutate: @Sendable @escaping (inout PersonalSyncState) -> Void) async {
        var state = await memory.loadSyncState()
        mutate(&state)
        await memory.saveSyncState(state)
    }

    func revisions(recordID: UUID) async -> [RecordRevision] {
        await memory.revisions(recordID: recordID)
    }

    func appendResolvedRevision(_ revision: RecordRevision) async {
        await memory.appendRevision(revision)
    }

    func restoreRevision(_ revisionID: UUID) async -> Bool {
        let all = await memory.allRevisions()
        guard let revision = all.first(where: { $0.id == revisionID }) else { return false }
        guard let data = revision.previousPayloadJSON.data(using: .utf8) else { return false }
        switch revision.recordKind {
        case .memory:
            guard var record = try? JSONDecoder.personalAI.decode(MemoryRecord.self, from: data) else { return false }
            record = record.touched()
            await memory.upsert([record])
            await memory.appendRevision(makeRevision(record, kind: .memory, reason: "user:restore-revision"))
            return true
        case .rule:
            guard var rule = try? JSONDecoder.personalAI.decode(Rule.self, from: data) else { return false }
            rule = rule.touched()
            await memory.upsertRule(rule)
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    private func makeRevision<T: PersonalCloudSyncable>(_ record: T, kind: PersonalRecordKind, reason: String) -> RecordRevision {
        let json = (try? JSONEncoder.personalAI.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return RecordRevision(
            recordID: record.id, recordKind: kind, version: record.revision,
            changedAt: Date(), source: .inferredFromConversation, reason: reason,
            previousPayloadJSON: json, previousRevision: record.revision
        )
    }
}
