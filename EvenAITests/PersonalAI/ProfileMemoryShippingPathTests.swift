import Testing
import Foundation
@testable import EvenAI

/// Shipping-composition regression for the real iPhone failure: a profile
/// fact stored via `"Запам'ятай: …"`, a **new conversation**, then an
/// identity question in another language — traced through the *actual*
/// `PersonalAIService` → `MemoryCommandProcessor` → `LocalPersonalMemoryStore`
/// → `DefaultPersonalAIContextBuilder` → `PersonalAIGenerationRequest` path
/// used by Personal AI Chat. Proves the name survives all the way to the
/// generation-request boundary, **prominently**, with no semantic model.
///
/// The un-testable piece is the real Apple `LanguageModelSession`; everything
/// up to (and including) what a provider receives is exercised here.
@MainActor
@Suite("Personal AI: profile memory — shipping composition")
struct ProfileMemoryShippingPathTests {

    private func tempStore() throws -> LocalPersonalMemoryStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("profship-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalPersonalMemoryStore(directory: dir)
    }

    /// A service wired the way `PersonalAIContainer.make` wires it: real
    /// local store, real `DefaultPersonalAIContextBuilder(store:)` (no
    /// semantic scorer → the shipping inert path), pluggable provider.
    private func service(
        store: LocalPersonalMemoryStore,
        provider: any PersonalAIModelProviding
    ) -> PersonalAIService {
        PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: provider,
            conversationStore: InMemoryPersonalAIConversationStore()
        )
    }

    private func profileFacts(_ ctx: PersonalAIContext) -> [MemoryRecord] {
        ctx.relevantMemories.filter { $0.category == .profile }
    }

    /// The prominent "Known facts about the user" section the renderer now emits.
    private func knownFactsSection(_ prompt: String) -> String? {
        guard let r = prompt.range(of: "Known facts about the user") else { return nil }
        let tail = String(prompt[r.lowerBound...])
        return String(tail.prefix(400))
    }

    // MARK: - the exact reported scenario

    @Test("\"Запам'ятай: мене звати Олег.\" → new conversation → \"What is my name?\": Oleg reaches the provider prominently")
    func reportedScenarioReachesProviderInput() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider(reply: "OK.")
        let svc = service(store: store, provider: recorder)

        await svc.send("Запам'ятай: мене звати Олег.")

        // a persistent, active .profile record exists
        let stored = await store.memories(matching: MemoryQuery(statuses: [.active]))
        let name = stored.first { $0.canonicalContent.localizedCaseInsensitiveContains("Олег") }
        #expect(name != nil)
        #expect(name?.category == .profile)
        #expect(name?.status == .active)
        #expect(name?.deletedAt == nil)

        await svc.startNewConversation()
        await svc.send("What is my name?")

        let req = try #require(await recorder.requests.last)
        // relevant memories carry it
        #expect(profileFacts(req.personalContext).contains { $0.canonicalContent.localizedCaseInsensitiveContains("Олег") })
        // system prompt carries it, in the explicit known-facts section
        let prompt = req.personalContext.systemPromptText
        #expect(prompt.contains("Олег"))
        let section = try #require(knownFactsSection(prompt))
        #expect(section.contains("Олег"))
        #expect(section.localizedCaseInsensitiveContains("may be relevant") == false)   // not the hedged block
        #expect(section.localizedCaseInsensitiveContains("answer directly and plainly"))
    }

    @Test("the same scenario, heuristic provider end-to-end, answers with Oleg")
    func reportedScenarioHeuristicReply() async throws {
        let store = try tempStore()
        let svc = service(store: store, provider: HeuristicPersonalAIModelProvider())
        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.startNewConversation()
        await svc.send("What is my name?")
        let reply = svc.messages.last { $0.role == .assistant }?.text ?? ""
        #expect(reply.localizedCaseInsensitiveContains("Олег"), "reply: \(reply)")
    }

    // MARK: - cross-language (§7)

    @Test("UK name fact, questions in UK/EN/DE/PL — Oleg in provider input + heuristic reply")
    func crossLanguageThroughService() async throws {
        for q in ["Як мене звати?", "What is my name?", "Wie heiße ich?", "Jak mam na imię?"] {
            let store = try tempStore()
            let recorder = FakePersonalAIModelProvider()
            let svc = service(store: store, provider: recorder)
            await svc.send("Мене звати Олег.")
            await svc.startNewConversation()
            await svc.send(q)

            let req = try #require(await recorder.requests.last)
            #expect(profileFacts(req.personalContext).contains { $0.canonicalContent.contains("Олег") }, "not retrieved for: \(q)")
            #expect(knownFactsSection(req.personalContext.systemPromptText)?.contains("Олег") == true, "not in known-facts section for: \(q)")

            let store2 = try tempStore()
            let svc2 = service(store: store2, provider: HeuristicPersonalAIModelProvider())
            await svc2.send("Мене звати Олег.")
            await svc2.startNewConversation()
            await svc2.send(q)
            #expect((svc2.messages.last { $0.role == .assistant }?.text ?? "").localizedCaseInsensitiveContains("Олег"), "heuristic reply missing name for: \(q)")
        }
    }

    // MARK: - other profile facts (§8)

    @Test("location fact through the service — Kyiv reaches provider + heuristic reply")
    func locationThroughService() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider()
        let svc = service(store: store, provider: recorder)
        await svc.send("Запам'ятай: я живу в Києві.")
        await svc.startNewConversation()
        await svc.send("Where do I live?")
        let req = try #require(await recorder.requests.last)
        #expect(knownFactsSection(req.personalContext.systemPromptText)?.localizedCaseInsensitiveContains("києв") == true)

        let store2 = try tempStore()
        let svc2 = service(store: store2, provider: HeuristicPersonalAIModelProvider())
        await svc2.send("Запам'ятай: я живу в Києві.")
        await svc2.startNewConversation()
        await svc2.send("Де я живу?")
        #expect((svc2.messages.last { $0.role == .assistant }?.text ?? "").localizedCaseInsensitiveContains("києв"))
    }

    @Test("occupation fact through the service — customs lawyer reaches provider + heuristic reply")
    func occupationThroughService() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider()
        let svc = service(store: store, provider: recorder)
        await svc.send("Запам'ятай: я працюю митним юристом.")
        await svc.startNewConversation()
        await svc.send("What do I do for work?")
        let req = try #require(await recorder.requests.last)
        #expect(knownFactsSection(req.personalContext.systemPromptText)?.localizedCaseInsensitiveContains("митн") == true)

        let store2 = try tempStore()
        let svc2 = service(store: store2, provider: HeuristicPersonalAIModelProvider())
        await svc2.send("Запам'ятай: я працюю митним юристом.")
        await svc2.startNewConversation()
        await svc2.send("Ким я працюю?")
        #expect((svc2.messages.last { $0.role == .assistant }?.text ?? "").localizedCaseInsensitiveContains("митн"))
    }

    // MARK: - negatives / safety (§9)

    @Test("an unrelated question does not promote profile facts into the provider input")
    func unrelatedQueryNoPromotion() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider()
        let svc = service(store: store, provider: recorder)
        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.send("Запам'ятай: я живу в Києві.")
        await svc.startNewConversation()
        await svc.send("What is the capital of France?")
        let req = try #require(await recorder.requests.last)
        #expect(req.personalContext.systemPromptText.contains("Known facts about the user") == false)
        #expect(req.personalContext.systemPromptText.contains("Олег") == false)
        #expect(req.personalContext.systemPromptText.localizedCaseInsensitiveContains("києв") == false)
    }

    @Test("memory off → the name never reaches the provider")
    func memoryOffThroughService() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider()
        let svc = service(store: store, provider: recorder)
        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.setMemoryEnabled(false)
        await svc.startNewConversation()
        await svc.send("What is my name?")
        let req = try #require(await recorder.requests.last)
        #expect(req.personalContext.memoryDisabled)
        #expect(req.personalContext.systemPromptText.contains("Олег") == false)
    }

    @Test("a deleted profile fact never reaches the provider")
    func deletedThroughService() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider()
        let svc = service(store: store, provider: recorder)
        await svc.send("Запам'ятай: мене звати Олег.")
        let stored = await store.allMemories()
        for r in stored { await store.deleteMemory(id: r.id) }
        await svc.startNewConversation()
        await svc.send("What is my name?")
        let req = try #require(await recorder.requests.last)
        #expect(req.personalContext.relevantMemories.isEmpty)
        #expect(req.personalContext.systemPromptText.contains("Олег") == false)
    }

    @Test("a current-instruction still renders above the known-facts section")
    func priorityPreservedThroughService() async throws {
        let store = try tempStore()
        let recorder = FakePersonalAIModelProvider()
        let svc = service(store: store, provider: recorder)
        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.startNewConversation()
        await svc.send("Always answer in one sentence. What is my name?")
        let prompt = try #require(await recorder.requests.last).personalContext.systemPromptText
        let instr = prompt.range(of: "answer in one sentence")
        let known = prompt.range(of: "Known facts about the user")
        #expect(instr != nil && known != nil)
        if let instr, let known { #expect(instr.lowerBound < known.lowerBound) }
    }

    @Test("no profile fact on file → no known-facts section, no fabricated name")
    func noFactThroughService() async throws {
        let store = try tempStore()
        let heur = HeuristicPersonalAIModelProvider()
        let svc = service(store: store, provider: heur)
        await svc.send("What is my name?")
        let reply = svc.messages.last { $0.role == .assistant }?.text ?? ""
        #expect(reply.localizedCaseInsensitiveContains("your name is") == false)
        #expect(reply.isEmpty == false)
    }

    // MARK: - success-path diagnostic (content-free)

    @Test("a successful turn emits a content-free PERSONAL_AI_CHAT diagnostic: provider + buildTrace metadata, never raw memory or user text")
    func successfulTurnEmitsContentFreeDiagnostic() async throws {
        let store = try tempStore()
        let svc = service(store: store, provider: HeuristicPersonalAIModelProvider())
        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.startNewConversation()

        let captured = await StdoutCapture.capture {
            await svc.send("What is my name?")
        }

        // the event fired, naming the provider that actually answered
        #expect(captured.contains("PERSONAL_AI_CHAT"))
        #expect(captured.contains("provider=heuristic"))
        #expect(captured.contains("memoryEnabled=yes"))
        // the builder's own content-free trace made it into the line
        #expect(captured.contains("knownProfile=1"))
        #expect(captured.range(of: #"retrieved=\d+/\d+"#, options: .regularExpression) != nil)

        // never the raw fact, never the raw question, never the assembled prompt
        #expect(captured.localizedCaseInsensitiveContains("Олег") == false)
        #expect(captured.contains("What is my name") == false)
        #expect(captured.contains("Known facts about the user") == false)
    }
}
