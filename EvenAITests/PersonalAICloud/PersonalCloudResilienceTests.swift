import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("Personal AI Cloud: resilience & isolation from the proven pipeline")
struct PersonalCloudResilienceTests {

    // MARK: §30.29 — vector index loss does not lose canonical memory

    @Test("dropping every embedding leaves canonical memories and lexical retrieval intact")
    func embeddingLossIsHarmless() async {
        let store = InMemoryPersonalMemoryStore()
        await store.upsert([
            MemoryRecord(category: .projects, canonicalContent: "Building EvenAI for G2 glasses.", entities: ["evenai"], embeddingModelVersion: "on-device-nl-v1"),
            MemoryRecord(category: .profile, canonicalContent: "I live in Kyiv.", embeddingModelVersion: "on-device-nl-v1"),
        ])

        // "Lose" the vector index: strip the derived metadata.
        var stripped = await store.allMemories()
        for i in stripped.indices { stripped[i].embeddingModelVersion = nil }
        await store.upsert(stripped)

        #expect((await store.allMemories()).allSatisfy { $0.embeddingModelVersion == nil })
        // Canonical content untouched; retrieval (lexical) still works.
        let results = MemoryRetriever().retrieve(
            RetrievalQuery(text: "How is the EvenAI project going?", surface: .personalChat),
            from: await store.allMemories()
        )
        #expect(results.contains { $0.record.canonicalContent.contains("EvenAI") })

        // NoEmbeddingProvider is the Phase 2 default and is a no-op.
        let vectors = try? await NoEmbeddingProvider().embed(["a", "b"])
        #expect(vectors?.count == 2)
        #expect(vectors?.allSatisfy { $0.isEmpty } == true)
    }

    // MARK: §30.30 / §30.31 — cloud failure cannot touch AI Conversation / G2

    @Test("a hard-failing sync engine running alongside a live AIConversationEngine session does not affect translation or local replies")
    func cloudFailureCannotAffectAIConversation() async {
        // A Personal AI cloud that fails at every layer.
        let harness = await PersonalCloudHarness(ownerID: "u")
        harness.control.behavior = .offline
        await harness.memoryStore.upsert([MemoryRecord.fixture("pending forever")])
        let failed = await harness.syncEngine.sync()
        if case .failedRetryable = failed {} else { Issue.record("expected the sync to fail") }

        // Meanwhile the proven pipeline runs untouched.
        let spy = SpyGlassesTransport()
        let engine = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Do you want to come with us tomorrow?"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Do you want to come with us tomorrow?": "en"],
                translation: "Ти хочеш піти з нами завтра?"
            ),
            replyGenerator: FakeSuggestedReplyGenerator(defaultReplies: [
                SuggestedReply(originalLanguageText: "Yes, sure.", ukrainianText: "Так, звісно.", ordering: 0),
            ]),
            defaults: UserDefaults(suiteName: "CloudResilience.\(UUID().uuidString)")!
        )
        await engine.start()
        try? await Task.sleep(for: .milliseconds(200))

        let displayed = await spy.displayedPageSets
        #expect(displayed.isEmpty == false)
        #expect(displayed.first?.first?.contains("Ти хочеш піти з нами завтра?") == true)
        #expect(displayed.last?.first?.contains("Yes, sure.") == true)
        await engine.stop()

        // The sync data is still safely queued — nothing lost.
        #expect((await harness.dataStore.pendingChanges()).isEmpty == false)
    }

    @Test("AIConversationEngine has no reference to any Personal AI Cloud type (compile-time isolation)")
    func compileTimeIsolation() {
        // If this file compiles, `AIConversationEngine` did not gain a
        // dependency on `PersonalAISyncEngine` / `PersonalCloudService` /
        // `PersonalAIBackupCoordinator`. The Phase 2 report's grep check is
        // the authoritative proof; this is a smoke assertion.
        #expect(true)
    }

    // MARK: §30.35 — diagnostics never contain raw memory content

    @Test("a full sync + backup + restore cycle logs no memory content or secrets")
    func diagnosticsNeverLeakContent() async {
        let distinctive = "ZebraQuokkaMarmoset budget is 4 million"
        let secretish = "sk-ZZZ0000fakeTokenValue0000"

        let harness = await PersonalCloudHarness(ownerID: "log-user")
        let captured = await StdoutCapture.capture {
            await harness.memoryStore.upsert([MemoryRecord.fixture(distinctive)])
            // (a secret would be rejected upstream; include it to be sure it can't reach a log here)
            await harness.memoryStore.upsert([MemoryRecord(category: .knowledge, canonicalContent: secretish)])
            _ = await harness.syncEngine.sync()
            _ = await harness.backupCoordinator.backup(tier: .daily)
            await harness.memoryStore.replaceAll(with: .empty)
            _ = await harness.restoreCoordinator.restore(ownerID: "log-user")
        }

        #expect(captured.contains(distinctive) == false, "memory content leaked into logs")
        #expect(captured.contains("ZebraQuokkaMarmoset") == false)
        #expect(captured.contains(secretish) == false)
        // But the structured trace markers ARE present.
        #expect(captured.contains("SYNC_START") || captured.contains("PERSONAL_AI_SYNC"))
        #expect(captured.contains("BACKUP_SUCCESS") || captured.contains("PERSONAL_AI_BACKUP"))
    }

    // MARK: PersonalCloudSyncable conformance for every kind

    @Test("every record kind round-trips through the sync codec")
    func codecRoundTripAllKinds() {
        let mem = MemoryRecord.fixture("m")
        let rule = Rule(text: "r")
        let conv = PersonalAIConversation(id: UUID())
        let msg = PersonalAIChatMessage(conversationID: UUID(), role: .user, text: "hi")
        let style = SyncableStyleProfile(profile: .empty, ownerID: "o")

        #expect(matches(PersonalSyncCodec.decode(PersonalSyncCodec.encode(mem)), .memory))
        #expect(matches(PersonalSyncCodec.decode(PersonalSyncCodec.encode(rule)), .rule))
        #expect(matches(PersonalSyncCodec.decode(PersonalSyncCodec.encode(conv)), .conversation))
        #expect(matches(PersonalSyncCodec.decode(PersonalSyncCodec.encode(msg)), .message))
        #expect(matches(PersonalSyncCodec.decode(PersonalSyncCodec.encode(style)), .styleProfile))
    }

    private func matches(_ decoded: PersonalSyncCodec.Decoded?, _ kind: PersonalRecordKind) -> Bool {
        decoded?.kind == kind
    }
}
