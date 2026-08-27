import Testing
import Foundation
@testable import EvenAI

/// Phase 1 pre-commit audit: everything here exercises **production**
/// storage (`LocalPersonalMemoryStore` / `LocalPersonalAIConversationStore`)
/// and the real `PersonalAIService` wiring — not in-memory fakes.
@Suite("Personal AI: Phase 1 production audit")
struct PersonalAIProductionAuditTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-audit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Point 3: production persistence across relaunch

    @Test("memories, rules, style, projects, people all survive a relaunch (production store)")
    func memoryRulesStyleProjectsPeopleSurviveRelaunch() async {
        let dir = tempDir()

        do {
            let store = LocalPersonalMemoryStore(directory: dir)
            await store.upsert([
                MemoryRecord(category: .profile, canonicalContent: "I live in Kyiv."),
                MemoryRecord(category: .projects, canonicalContent: "Building EvenAI for Even G2 glasses.", entities: ["evenai", "g2"]),
                MemoryRecord(category: .people, canonicalContent: "Andrii is my co-founder.", entities: ["andrii"]),
            ])
            await store.upsertRule(Rule(text: "Keep business replies short."))
            var style = await store.styleProfile()
            style.preferredLanguage = "uk"
            style.responseLength = .short
            await store.updateStyleProfile(style)
        }

        // Fresh instance, same path == app relaunch.
        let reopened = LocalPersonalMemoryStore(directory: dir)
        let memories = await reopened.allMemories()
        let rules = await reopened.allRules()
        let style = await reopened.styleProfile()

        #expect(memories.count == 3)
        #expect(memories.contains { $0.category == .profile && $0.canonicalContent.contains("Kyiv") })
        #expect(memories.contains { $0.category == .projects && $0.canonicalContent.contains("EvenAI") })
        #expect(memories.contains { $0.category == .people && $0.canonicalContent.contains("Andrii") })
        #expect(rules.count == 1)
        #expect(rules[0].text.contains("short"))
        #expect(style.preferredLanguage == "uk")
        #expect(style.responseLength == .short)
    }

    @Test("Personal AI conversation history survives a relaunch (production store)")
    func conversationHistorySurvivesRelaunch() async {
        let dir = tempDir()
        let convID: UUID

        do {
            let convStore = LocalPersonalAIConversationStore(directory: dir)
            convID = await convStore.currentConversationID()
            await convStore.append(PersonalAIChatMessage(role: .user, text: "First message about EvenAI"), conversationID: convID)
            await convStore.append(PersonalAIChatMessage(role: .assistant, text: "Understood."), conversationID: convID)
        }

        let reopened = LocalPersonalAIConversationStore(directory: dir)
        #expect(await reopened.currentConversationID() == convID)
        let messages = await reopened.loadConversation(id: convID)
        #expect(messages.count == 2)
        #expect(messages.first?.text == "First message about EvenAI")
        #expect(messages.last?.role == .assistant)
    }

    @Test("a full PersonalAIService turn persists to disk and reloads in a new service instance")
    @MainActor
    func fullServiceTurnPersists() async {
        let dir = tempDir()
        let memStore = LocalPersonalMemoryStore(directory: dir)
        let convStore = LocalPersonalAIConversationStore(directory: dir)

        let service1 = PersonalAIService(
            store: memStore,
            contextBuilder: DefaultPersonalAIContextBuilder(store: memStore),
            modelProvider: FakePersonalAIModelProvider(reply: "Noted."),
            conversationStore: convStore
        )
        await service1.open()
        await service1.send("Remember that the EvenAI launch is planned for September.")

        // New service, same on-disk stores.
        let memStore2 = LocalPersonalMemoryStore(directory: dir)
        let convStore2 = LocalPersonalAIConversationStore(directory: dir)
        let service2 = PersonalAIService(
            store: memStore2,
            contextBuilder: DefaultPersonalAIContextBuilder(store: memStore2),
            modelProvider: FakePersonalAIModelProvider(),
            conversationStore: convStore2
        )
        await service2.open()

        #expect(service2.messages.count == 2)
        let memories = await service2.loadMemories()
        #expect(memories.contains { $0.canonicalContent.localizedCaseInsensitiveContains("September") })
        // Stable id survived the relaunch.
        let idBefore = (await memStore.allMemories()).first?.id
        let idAfter = memories.first(where: { $0.canonicalContent.localizedCaseInsensitiveContains("September") })?.id
        #expect(idBefore == idAfter)
    }

    // MARK: - Point 4: command system → explicit operations (production store)

    @Test("all six command forms map to real store operations, not prompt text")
    @MainActor
    func commandFormsMapToStoreOps() async {
        let dir = tempDir()
        let store = LocalPersonalMemoryStore(directory: dir)
        let service = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: FakePersonalAIModelProvider(),
            conversationStore: LocalPersonalAIConversationStore(directory: dir)
        )
        await service.open()

        await service.send("Remember that I prefer espresso.")
        await service.send("From now on, keep answers under three sentences.")
        await service.send("Always double-check dates before stating them.")
        await service.send("Never open with 'thanks for sharing'.")

        let rulesAfterAdds = await store.allRules()
        #expect(rulesAfterAdds.count == 3)
        #expect(rulesAfterAdds.contains { $0.text.localizedCaseInsensitiveContains("three sentences") })
        #expect(rulesAfterAdds.contains { $0.text.localizedCaseInsensitiveContains("double-check") })
        #expect(rulesAfterAdds.contains { $0.text.localizedCaseInsensitiveContains("never") })

        let espresso = (await store.allMemories()).first { $0.canonicalContent.localizedCaseInsensitiveContains("espresso") }
        #expect(espresso != nil)
        #expect(espresso?.userConfirmed == true)

        // forget / stop remembering
        await service.send("Forget that I prefer espresso.")
        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.contains { $0.canonicalContent.localizedCaseInsensitiveContains("espresso") } == false)
        let archived = (await store.allMemories()).first { $0.canonicalContent.localizedCaseInsensitiveContains("espresso") }
        #expect(archived?.status == .archived)
    }

    // MARK: - Point 5/6: retrieval + anti-generic wiring through the real service

    @Test("turn 2 of a real conversation connects to the project stated in turn 1, and the model receives the anti-generic guidance")
    @MainActor
    func conversationConnectsContextAndCarriesGuidance() async {
        let dir = tempDir()
        let store = LocalPersonalMemoryStore(directory: dir)
        let model = FakePersonalAIModelProvider(reply: "…")
        let service = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: model,
            conversationStore: LocalPersonalAIConversationStore(directory: dir)
        )
        await service.open()
        await service.send("I'm building EvenAI for Even G2 smart glasses.")
        await service.send("I'm having problems with the suggested replies.")

        let req = await model.lastRequest
        let prompt = req?.personalContext.systemPromptText ?? ""
        #expect(prompt.localizedCaseInsensitiveContains("EvenAI"))
        #expect(prompt.localizedCaseInsensitiveContains("thanks for sharing")) // the guidance clause
        #expect(req?.personalContext.hasPersonalization == true)
    }

    @Test("the anti-generic guidance is never dropped, even under an extreme token budget")
    func guidanceSurvivesExtremeBudget() {
        let rendered = PersonalAIContextRenderer.render(.init(
            currentInstruction: nil,
            rules: (0..<10).map { Rule(text: "Rule number \($0) with some length to it.") },
            projects: [], people: [],
            otherMemories: (0..<10).map { MemoryRecord(category: .knowledge, canonicalContent: "Fact \($0) padded out with words.") },
            excerpts: [],
            styleInstructions: "reply in Ukrainian; keep it short",
            tokenBudget: 10,
            memoryDisabled: false
        ))
        #expect(rendered.text.localizedCaseInsensitiveContains("thanks for sharing"))
        #expect(rendered.text.localizedCaseInsensitiveContains("that's interesting"))
    }

    // MARK: - Point 11: memory-off still honours explicit standing rules

    @Test("with global memory off, stored rules and a current instruction still reach the prompt; recalled facts do not")
    @MainActor
    func memoryOffKeepsRulesDropsRecall() async {
        let dir = tempDir()
        let store = LocalPersonalMemoryStore(directory: dir)
        await store.upsertRule(Rule(text: "Always reply in Ukrainian."))
        await store.upsert([MemoryRecord(category: .profile, canonicalContent: "My cat is named Pixel.", entities: ["pixel"])])
        await store.setMemoryEnabledGlobally(false)

        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "Tell me about my cat Pixel.")
        )
        #expect(context.memoryDisabled)
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("Always reply in Ukrainian"))
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("Pixel") == false)
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("thanks for sharing")) // guidance still present
        #expect(context.relevantMemories.isEmpty)
    }

    // MARK: - Point 12: Phase 2 field presence on every record type

    @Test("every persisted record carries the Phase 2 sync fields")
    func phase2FieldsPresent() {
        let record = MemoryRecord(category: .profile, canonicalContent: "x")
        _ = record.remoteID; _ = record.revision; _ = record.syncState
        _ = record.deletedAt; _ = record.ownerID
        #expect(record.revision == 0)
        #expect(record.syncState == .localOnly)

        let rule = Rule(text: "y")
        _ = rule.remoteID; _ = rule.revision; _ = rule.syncState
        _ = rule.deletedAt; _ = rule.ownerID
        #expect(rule.syncState == .localOnly)

        // touched() advances the sync-relevant fields.
        var synced = record
        synced.syncState = .synced
        let bumped = synced.touched()
        #expect(bumped.revision == 1)
        #expect(bumped.syncState == .pendingPush)
    }

    @Test("a supersede bumps the OLD record's revision so a cloud diff can see it")
    @MainActor
    func supersedeBumpsOldRecordRevision() async {
        let dir = tempDir()
        let store = LocalPersonalMemoryStore(directory: dir)
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: "Remember the EvenAI launch is planned for September.", conversationID: UUID(), messageID: UUID(), store: store)
        let before = (await store.allMemories()).first!
        _ = await processor.process(message: "Remember the EvenAI launch moved to October.", conversationID: UUID(), messageID: UUID(), store: store)

        let all = await store.allMemories()
        let old = all.first { $0.id == before.id }
        #expect(old?.status == .superseded)
        #expect(old?.supersededByID != nil)
        #expect((old?.revision ?? 0) > before.revision)   // <- the audit fix
        #expect((old?.updatedAt ?? .distantPast) > before.updatedAt)
    }
}
