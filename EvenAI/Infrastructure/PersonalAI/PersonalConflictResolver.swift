import Foundation

/// Applies the deterministic `ConflictPolicy` for a record kind to a pair of
/// conflicting versions (local vs server) and returns the version to keep.
/// The same two inputs always converge to the same result regardless of
/// which device syncs first, and the losing side is preserved — either as a
/// `RecordRevision` or, when the two versions are genuinely different facts,
/// re-issued under a fresh id so nothing is lost.
struct PersonalConflictResolver: Sendable {
    private let merger: MemoryMerger

    init(merger: MemoryMerger = MemoryMerger()) {
        self.merger = merger
    }

    struct Resolution: Sendable {
        /// The resolved envelope to persist locally and re-push.
        var resolved: SyncRecordEnvelope
        /// A second record (fresh id) when the local version was a distinct
        /// fact worth keeping alongside the server's.
        var reissued: SyncRecordEnvelope?
        /// A revision capturing whichever side was replaced.
        var revision: RecordRevision?
    }

    func resolve(_ conflict: SyncConflict, now: Date = .now) -> Resolution? {
        guard
            let local = PersonalSyncCodec.decode(SyncRecordEnvelope(
                kind: conflict.kind, id: conflict.id, remoteID: conflict.serverRemoteID,
                baseRevision: 0, payloadJSON: conflict.clientPayloadJSON, deletedAt: nil)),
            let server = PersonalSyncCodec.decode(SyncRecordEnvelope(
                kind: conflict.kind, id: conflict.id, remoteID: conflict.serverRemoteID,
                baseRevision: 0, payloadJSON: conflict.serverPayloadJSON, deletedAt: conflict.serverDeletedAt))
        else { return nil }

        // A tombstone on the server always wins — never resurrect.
        if conflict.serverDeletedAt != nil {
            var env = rebasedServerEnvelope(conflict)
            env.deletedAt = conflict.serverDeletedAt
            return Resolution(
                resolved: env,
                revision: revision(recordID: conflict.id, revision: local.revision, json: local.payloadJSON, kind: conflict.kind, reason: "sync:tombstone-wins", now: now)
            )
        }

        switch ConflictPolicy.forKind(conflict.kind) {
        case .semanticMerge:
            return resolveMemory(conflict: conflict, local: local, server: server, now: now)
        case .ruleUnion:
            return resolveRule(conflict: conflict, local: local, server: server, now: now)
        case .appendOnly:
            // Messages never overwrite — the server copy is authoritative
            // history.
            return Resolution(resolved: rebasedServerEnvelope(conflict))
        case .highestRevisionThenNewest:
            return resolveConversation(conflict: conflict, local: local, server: server)
        case .newestWins:
            return resolveStyle(conflict: conflict, local: local, server: server, now: now)
        }
    }

    // MARK: - Per-kind

    private func resolveMemory(conflict: SyncConflict, local: PersonalSyncCodec.Decoded, server: PersonalSyncCodec.Decoded, now: Date) -> Resolution {
        guard case .memory(let localMem) = local, case .memory(var serverMem) = server else {
            return Resolution(resolved: rebasedServerEnvelope(conflict))
        }
        let decision = merger.reconcile(
            candidate: MemoryCandidate(record: localMem, rationale: "sync:conflict"),
            against: [serverMem], now: now
        )
        switch decision {
        case .create:
            // Two genuinely different facts: keep the server's live, and
            // re-issue the local one under a fresh id so it is not lost.
            var reissued = localMem
            reissued = MemoryRecord(
                category: reissued.category, scope: reissued.scope,
                canonicalContent: reissued.canonicalContent, structured: reissued.structured,
                entities: reissued.entities, createdAt: reissued.createdAt, updatedAt: now,
                confidence: reissued.confidence, importance: reissued.importance,
                userConfirmed: reissued.userConfirmed, pinned: reissued.pinned,
                enabled: reissued.enabled, status: reissued.status, expiresAt: reissued.expiresAt,
                sourceConversationIDs: reissued.sourceConversationIDs, sourceMessageIDs: reissued.sourceMessageIDs
            )
            reissued.syncState = .pendingPush
            reissued.ownerID = localMem.ownerID
            serverMem.revision = conflict.serverRevision
            serverMem.remoteID = conflict.serverRemoteID
            serverMem.syncState = .synced
            return Resolution(
                resolved: PersonalSyncCodec.encode(serverMem),
                reissued: PersonalSyncCodec.encode(reissued)
            )
        case .duplicate(_, let refreshed):
            return finalize(refreshed, conflict: conflict, replaced: localMem, reason: "sync:conflict-duplicate", now: now)
        case .mergeInto(_, let merged):
            return finalize(merged, conflict: conflict, replaced: localMem, reason: "sync:conflict-merge", now: now)
        case .supersede(_, let newRecord):
            return finalize(newRecord, conflict: conflict, replaced: localMem, reason: "sync:conflict-supersede", now: now)
        case .reject:
            return Resolution(resolved: rebasedServerEnvelope(conflict))
        }
    }

    private func finalize(_ record: MemoryRecord, conflict: SyncConflict, replaced: MemoryRecord, reason: String, now: Date) -> Resolution {
        var keep = record
        keep.revision = conflict.serverRevision
        keep.remoteID = conflict.serverRemoteID
        keep.syncState = .pendingPush
        return Resolution(
            resolved: PersonalSyncCodec.encode(keep),
            revision: revision(recordID: conflict.id, revision: replaced.revision, json: (try? JSONEncoder.personalAI.encode(replaced)).flatMap { String(data: $0, encoding: .utf8) } ?? "", kind: .memory, reason: reason, now: now)
        )
    }

    private func resolveRule(conflict: SyncConflict, local: PersonalSyncCodec.Decoded, server: PersonalSyncCodec.Decoded, now: Date) -> Resolution {
        guard case .rule(let localRule) = local, case .rule(var serverRule) = server else {
            return Resolution(resolved: rebasedServerEnvelope(conflict))
        }
        // Deterministic: newest edit wins the text (tiebreak by id string);
        // `enabled` is the union so a rule disabled on one device and edited
        // on another ends up disabled, not silently re-enabled — and the
        // losing text is kept as a revision.
        let localNewer = (localRule.updatedAt, localRule.id.uuidString) > (serverRule.updatedAt, serverRule.id.uuidString)
        let winnerText = localNewer ? localRule.text : serverRule.text
        let loser = localNewer ? serverRule : localRule
        serverRule.text = winnerText
        serverRule.enabled = localRule.enabled && serverRule.enabled
        serverRule.revision = conflict.serverRevision
        serverRule.remoteID = conflict.serverRemoteID
        serverRule.syncState = .pendingPush
        serverRule.updatedAt = now
        return Resolution(
            resolved: PersonalSyncCodec.encode(serverRule),
            revision: revision(recordID: conflict.id, revision: loser.revision,
                               json: (try? JSONEncoder.personalAI.encode(loser)).flatMap { String(data: $0, encoding: .utf8) } ?? "",
                               kind: .rule, reason: "sync:rule-union", now: now)
        )
    }

    private func resolveConversation(conflict: SyncConflict, local: PersonalSyncCodec.Decoded, server: PersonalSyncCodec.Decoded) -> Resolution {
        guard case .conversation(let localConv) = local, case .conversation(let serverConv) = server else {
            return Resolution(resolved: rebasedServerEnvelope(conflict))
        }
        let keepLocal = (localConv.revision, localConv.updatedAt, localConv.id.uuidString)
            > (serverConv.revision, serverConv.updatedAt, serverConv.id.uuidString)
        var winner = keepLocal ? localConv : serverConv
        winner.revision = conflict.serverRevision
        winner.remoteID = conflict.serverRemoteID
        winner.syncState = .pendingPush
        return Resolution(resolved: PersonalSyncCodec.encode(winner))
    }

    private func resolveStyle(conflict: SyncConflict, local: PersonalSyncCodec.Decoded, server: PersonalSyncCodec.Decoded, now: Date) -> Resolution {
        guard case .styleProfile(let localStyle) = local, case .styleProfile(let serverStyle) = server else {
            return Resolution(resolved: rebasedServerEnvelope(conflict))
        }
        let keepLocal = (localStyle.updatedAt, localStyle.id.uuidString) > (serverStyle.updatedAt, serverStyle.id.uuidString)
        var winner = keepLocal ? localStyle : serverStyle
        let loser = keepLocal ? serverStyle : localStyle
        winner.revision = conflict.serverRevision
        winner.remoteID = conflict.serverRemoteID
        winner.syncState = .pendingPush
        return Resolution(
            resolved: PersonalSyncCodec.encode(winner),
            revision: revision(recordID: conflict.id, revision: loser.revision,
                               json: (try? JSONEncoder.personalAI.encode(loser)).flatMap { String(data: $0, encoding: .utf8) } ?? "",
                               kind: .styleProfile, reason: "sync:style-newest-wins", now: now)
        )
    }

    // MARK: - Helpers

    private func rebasedServerEnvelope(_ conflict: SyncConflict) -> SyncRecordEnvelope {
        var env = SyncRecordEnvelope(
            kind: conflict.kind, id: conflict.id, remoteID: conflict.serverRemoteID,
            baseRevision: conflict.serverRevision, payloadJSON: conflict.serverPayloadJSON,
            deletedAt: conflict.serverDeletedAt
        )
        env.serverRevision = conflict.serverRevision
        return env
    }

    private func revision(recordID: UUID, revision: Int, json: String, kind: PersonalRecordKind, reason: String, now: Date) -> RecordRevision? {
        guard !json.isEmpty else { return nil }
        return RecordRevision(
            recordID: recordID, recordKind: kind, version: revision,
            changedAt: now, source: .inferredFromConversation, reason: reason,
            previousPayloadJSON: json, previousRevision: revision
        )
    }
}
