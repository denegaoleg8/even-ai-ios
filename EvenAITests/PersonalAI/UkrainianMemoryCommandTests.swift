import Testing
import Foundation
@testable import EvenAI

/// Ukrainian Personal AI memory commands — the fix for "Запам'ятай: …" not
/// being understood or persisted. Covers the centralised apostrophe / colon
/// normalisation, the Ukrainian trigger grammar, passive Ukrainian
/// classification, and the full write → store → retrieve path. English
/// behaviour is re-checked alongside to guard against regression.
///
/// Retrieval on `.g2Replies` (Phase 3) is exercised here **read-only** — no
/// Phase 3 code is touched; the tests only prove a stored Ukrainian memory
/// is reachable through the existing `DefaultPersonalAIContextBuilder`.

// MARK: - 1–11  Ukrainian command interpretation

@Suite("Ukrainian Personal AI: command interpretation")
struct UkrainianCommandInterpreterTests {

    private let interpreter = CommandInterpreter()

    private func remember(in commands: [MemoryCommand]) -> (content: String, category: MemoryCategory)? {
        for case let .remember(content, category) in commands { return (content, category) }
        return nil
    }

    // 1 — the exact acceptance command
    @Test("acceptance: \"Запам'ятай: коли я говорю про каву…\" → one remember, preference category")
    func acceptanceCommand() {
        let commands = interpreter.interpret("Запам'ятай: коли я говорю про каву, я віддаю перевагу еспресо без цукру.")
        #expect(commands.count == 1)
        let r = remember(in: commands)
        #expect(r != nil)
        #expect(r?.category == .preferences)
        #expect(r?.content.localizedCaseInsensitiveContains("каву") == true)
        #expect(r?.content.localizedCaseInsensitiveContains("еспресо") == true)
        #expect(r?.content.localizedCaseInsensitiveContains("запам") == false)   // trigger stripped
    }

    // 2 — U+2019 typographic apostrophe
    @Test("apostrophe U+2019 (’) is recognised")
    func apostropheTypographic() {
        let commands = interpreter.interpret("Запам\u{2019}ятай: я люблю еспресо.")
        #expect(remember(in: commands)?.content == "я люблю еспресо")
    }

    // 3 — U+0027 ASCII apostrophe
    @Test("apostrophe U+0027 (') is recognised")
    func apostropheASCII() {
        let commands = interpreter.interpret("Запам\u{27}ятай: я люблю еспресо.")
        #expect(remember(in: commands)?.content == "я люблю еспресо")
    }

    // 4 — U+02BC modifier-letter apostrophe
    @Test("apostrophe U+02BC (ʼ) is recognised")
    func apostropheModifierLetter() {
        let commands = interpreter.interpret("Запам\u{02BC}ятай: я люблю еспресо.")
        #expect(remember(in: commands)?.content == "я люблю еспресо")
    }

    // 5 — no colon, lower-case, no trailing punctuation
    @Test("bare \"запам'ятай я люблю еспресо\" (no colon, lower-case) is recognised")
    func noColonLowercase() {
        let commands = interpreter.interpret("запам'ятай я люблю еспресо")
        #expect(remember(in: commands)?.content == "я люблю еспресо")
    }

    // 6 — surrounding / interior whitespace is normalised, content preserved
    @Test("surrounding and post-colon whitespace is trimmed, memory content preserved")
    func whitespaceNormalised() {
        let commands = interpreter.interpret("  Запам'ятай:   я люблю еспресо  ")
        #expect(remember(in: commands)?.content == "я люблю еспресо")
    }

    // 7 — "Завжди …" → rule
    @Test("\"Завжди …\" creates a behavioural rule")
    func zavzhdyRule() {
        let commands = interpreter.interpret("Завжди відповідай мені українською.")
        guard case let .addRule(text, scope) = commands.first else { Issue.record("not a rule: \(commands)"); return }
        #expect(text.localizedCaseInsensitiveContains("завжди"))
        #expect(text.localizedCaseInsensitiveContains("українською"))
        #expect(scope == .global)
    }

    // 8 — "Ніколи …" → rule
    @Test("\"Ніколи …\" creates a behavioural rule")
    func nikolyRule() {
        let commands = interpreter.interpret("Ніколи не згадуй про мою відпустку.")
        guard case let .addRule(text, _) = commands.first else { Issue.record("not a rule: \(commands)"); return }
        #expect(text.localizedCaseInsensitiveContains("ніколи"))
    }

    // 9 — "Забудь про …" → forget
    @Test("\"Забудь про …\" is a forget with the topic as the query")
    func zabudProForget() {
        let commands = interpreter.interpret("Забудь про мою відпустку.")
        guard case let .forget(query) = commands.first else { Issue.record("not a forget: \(commands)"); return }
        #expect(query.localizedCaseInsensitiveContains("відпустку"))
        #expect(query.localizedCaseInsensitiveContains("забудь") == false)
    }

    // 10 — bare "Забудь …" → forget
    @Test("bare \"Забудь …\" is a forget")
    func zabudForget() {
        let commands = interpreter.interpret("Забудь мою адресу.")
        guard case let .forget(query) = commands.first else { Issue.record("not a forget: \(commands)"); return }
        #expect(query.localizedCaseInsensitiveContains("адресу"))
    }

    // 11 — "Відповідай коротко" → style
    @Test("\"Відповідай коротко\" is a style directive")
    func vidpovidayKorotkoStyle() {
        let commands = interpreter.interpret("Відповідай коротко.")
        guard case let .setStyle(directive) = commands.first else { Issue.record("not a style: \(commands)"); return }
        #expect(directive.localizedCaseInsensitiveContains("коротко"))
    }
}

// MARK: - 12–16  English regression (must not break)

@Suite("Ukrainian fix: English command regression")
struct EnglishCommandRegressionTests {

    private let interpreter = CommandInterpreter()

    // 12
    @Test("English \"Remember that …\" still creates a remember, category intact")
    func englishRemember() {
        let commands = interpreter.interpret("Remember that I'm building EvenAI for G2 glasses.")
        guard case let .remember(_, category) = commands.first else { Issue.record("not a remember: \(commands)"); return }
        #expect(category == .projects)
    }

    // 13
    @Test("English \"From now on, …\" still creates a rule")
    func englishFromNowOn() {
        guard case .addRule = interpreter.interpret("From now on, keep replies short.").first else {
            Issue.record("not a rule"); return
        }
    }

    // 14
    @Test("English \"Always …\" / \"Never …\" still create rules")
    func englishAlwaysNever() {
        guard case .addRule = interpreter.interpret("Always double-check dates before stating them.").first else {
            Issue.record("always → not a rule"); return
        }
        guard case .addRule = interpreter.interpret("Never open with 'thanks for sharing'.").first else {
            Issue.record("never → not a rule"); return
        }
    }

    // 15
    @Test("English \"Forget about …\" still archives")
    func englishForget() {
        guard case let .forget(query) = interpreter.interpret("Forget about my dentist appointment.").first else {
            Issue.record("not a forget"); return
        }
        #expect(query.localizedCaseInsensitiveContains("dentist"))
    }

    // 16
    @Test("English colon form now works, and a plain statement is still not a command")
    func englishColonAndPlain() {
        guard case let .remember(content, _) = interpreter.interpret("Remember: I prefer tea over coffee.").first else {
            Issue.record("colon remember failed"); return
        }
        #expect(content.localizedCaseInsensitiveContains("tea"))
        #expect(interpreter.interpret("I had a good meeting with the team today.").isEmpty)
        #expect(interpreter.interpret("What do you think about the launch date?").isEmpty)
    }
}

// MARK: - 17–21  MemoryCommandProcessor (Ukrainian, through the real store)

@Suite("Ukrainian Personal AI: command processing")
struct UkrainianMemoryCommandProcessorTests {

    private let acceptance = "Запам'ятай: коли я говорю про каву, я віддаю перевагу еспресо без цукру."

    // 17 — end-to-end write of the exact acceptance command
    @Test("the acceptance command produces one durable, active, confirmed memory")
    func acceptanceWritesMemory() async {
        let store = InMemoryPersonalMemoryStore()
        let outcomes = await MemoryCommandProcessor().process(
            message: acceptance, conversationID: UUID(), messageID: UUID(), store: store
        )
        #expect(outcomes.contains { if case .remembered = $0.kind { return true } else { return false } })

        let all = await store.allMemories()
        #expect(all.count == 1)
        let m = all[0]
        #expect(m.status == .active)
        #expect(m.enabled)
        #expect(m.deletedAt == nil)
        #expect(m.userConfirmed)
        #expect(m.category == .preferences)
        #expect(m.canonicalContent.localizedCaseInsensitiveContains("еспресо"))
        #expect(m.canonicalContent.hasSuffix("."))
    }

    // 18
    @Test("\"Завжди …\" is stored as an enabled active rule")
    func zavzhdyStoresRule() async {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: "Завжди відповідай українською.", conversationID: UUID(), messageID: UUID(), store: store
        )
        let rules = await store.allRules()
        #expect(rules.count == 1)
        #expect(rules[0].enabled)
        #expect(rules[0].priority == .activeRule)
        #expect(rules[0].text.localizedCaseInsensitiveContains("українськ"))
    }

    // 19 — Ukrainian forget uses the existing archive/tombstone path
    @Test("\"Забудь про каву\" archives + disables the coffee memory via the existing deletion path")
    func zabudArchivesMemory() async {
        let store = InMemoryPersonalMemoryStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: acceptance, conversationID: UUID(), messageID: UUID(), store: store)
        _ = await processor.process(message: "Запам'ятай: я живу в Києві.", conversationID: UUID(), messageID: UUID(), store: store)

        let outcomes = await processor.process(message: "Забудь про каву.", conversationID: UUID(), messageID: UUID(), store: store)
        #expect(outcomes.contains { if case .forgotten = $0.kind { return true } else { return false } })

        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.count == 1)
        #expect(active[0].canonicalContent.localizedCaseInsensitiveContains("києв"))

        let coffee = await store.allMemories().first { $0.canonicalContent.localizedCaseInsensitiveContains("еспресо") }
        #expect(coffee?.status == .archived)
        #expect(coffee?.enabled == false)
    }

    // 20
    @Test("\"Відповідай коротко\" updates the style profile and records a rule")
    func vidpovidayKorotkoUpdatesStyle() async {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: "Відповідай коротко.", conversationID: UUID(), messageID: UUID(), store: store
        )
        let profile = await store.styleProfile()
        #expect(profile.responseLength == .short)
        #expect(await store.allRules().isEmpty == false)
    }

    // 21 — a "Забудь …" with no match reports it and changes nothing
    @Test("\"Забудь …\" with no matching memory reports no-match, changes nothing")
    func zabudNoMatch() async {
        let store = InMemoryPersonalMemoryStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: acceptance, conversationID: UUID(), messageID: UUID(), store: store)
        let outcomes = await processor.process(message: "Забудь про мій улюблений колір.", conversationID: UUID(), messageID: UUID(), store: store)
        #expect(outcomes.contains { $0.kind == .noMatchToForget })
        #expect(await store.memories(matching: MemoryQuery(statuses: [.active])).count == 1)
    }
}

// MARK: - 22–25  HeuristicMemoryExtractor (Ukrainian passive classification)

@Suite("Ukrainian Personal AI: passive extraction")
struct UkrainianHeuristicExtractorTests {

    private let extractor = HeuristicMemoryExtractor()

    private func extract(_ text: String, enabled: Bool = true) async -> [MemoryCandidate] {
        await extractor.extract(
            from: PersonalAIExchange(conversationID: UUID(), surface: .personalChat, userText: text),
            existing: [], excludedConversationIDs: [], memoryEnabled: enabled
        )
    }

    // 22
    @Test("\"Я віддаю перевагу еспресо без цукру\" → passive preference")
    func ukrainianPreferenceCaptured() async {
        let c = await extract("Я віддаю перевагу еспресо без цукру.")
        #expect(c.count == 1)
        #expect(c[0].record.category == .preferences)
        #expect(c[0].record.userConfirmed == false)
    }

    // 23
    @Test("\"Мене звати Олег, я працюю в стартапі\" → passive profile fact")
    func ukrainianProfileCaptured() async {
        let c = await extract("Мене звати Олег, і я працюю в невеликому стартапі.")
        #expect(c.first?.record.category == .profile)
    }

    // 24 — negative: an ordinary Ukrainian question is not durable
    @Test("an ordinary Ukrainian question is not captured")
    func ukrainianQuestionNotCaptured() async {
        #expect(await extract("Яку каву мені краще замовити сьогодні?").isEmpty)
    }

    // 25 — negative: Ukrainian filler + a neutral statement are not captured
    @Test("Ukrainian filler and a neutral remark are not captured")
    func ukrainianFillerNotCaptured() async {
        #expect(await extract("Дуже дякую, це дуже допомогло!").isEmpty)
        #expect(await extract("Сьогодні був доволі напружений день.").isEmpty)
        #expect(await extract("Думаю, варто скоро зустрітися з командою.").isEmpty)
    }
}

// MARK: - 26–32  Integration: write → store → retrieve

@MainActor
@Suite("Ukrainian Personal AI: end-to-end memory + retrieval")
struct UkrainianMemoryIntegrationTests {

    private let acceptance = "Запам'ятай: коли я говорю про каву, я віддаю перевагу еспресо без цукру."
    private let coffeePrompt = "Яку каву мені замовити?"

    private func seededStore() async -> InMemoryPersonalMemoryStore {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: acceptance, conversationID: UUID(), messageID: UUID(), store: store
        )
        return store
    }

    // 26 — visible via loadMemories-equivalent + retrievable in Personal Chat
    @Test("stored Ukrainian memory is listed and retrieved for a coffee question (personalChat)")
    func retrievedInPersonalChat() async {
        let store = await seededStore()
        #expect(await store.memories(matching: MemoryQuery(statuses: [.active])).count == 1)

        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: coffeePrompt)
        )
        #expect(context.relevantMemories.contains { $0.canonicalContent.localizedCaseInsensitiveContains("еспресо") })
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("еспресо"))
    }

    // 27 — G2 retrieval seam (verify-only, no Phase 3 change)
    @Test("stored Ukrainian memory is retrievable through the .g2Replies surface")
    func retrievedOnG2Surface() async {
        let store = await seededStore()
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .g2Replies, userMessage: coffeePrompt)
        )
        #expect(context.relevantMemories.contains { $0.canonicalContent.localizedCaseInsensitiveContains("еспресо") })
    }

    // 28 — memory disabled globally → not used on .g2Replies
    @Test("memory disabled globally → the Ukrainian memory does not enter the .g2Replies context")
    func memoryDisabledContractPreserved() async {
        let store = await seededStore()
        await store.setMemoryEnabledGlobally(false)
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .g2Replies, userMessage: coffeePrompt)
        )
        #expect(context.memoryDisabled)
        #expect(context.relevantMemories.isEmpty)
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("еспресо") == false)
    }

    // 29 — forgotten Ukrainian memory is absent from retrieval / .g2Replies
    @Test("a \"Забудь …\"-forgotten Ukrainian memory never re-enters retrieval")
    func forgottenMemoryNotRetrieved() async {
        let store = await seededStore()
        _ = await MemoryCommandProcessor().process(
            message: "Забудь про каву.", conversationID: UUID(), messageID: UUID(), store: store
        )
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .g2Replies, userMessage: coffeePrompt)
        )
        #expect(context.relevantMemories.isEmpty)
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("еспресо") == false)
    }

    // 30 — persistence / reload (software evidence, not a physical relaunch)
    @Test("Ukrainian memory survives a store reload from disk and is still retrievable")
    func survivesStoreReload() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ua-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writeStore = LocalPersonalMemoryStore(directory: dir)
        _ = await MemoryCommandProcessor().process(
            message: acceptance, conversationID: UUID(), messageID: UUID(), store: writeStore
        )
        #expect(await writeStore.allMemories().count == 1)

        // Fresh instance, same directory → simulates an app relaunch.
        let reloaded = LocalPersonalMemoryStore(directory: dir)
        let persisted = await reloaded.allMemories()
        #expect(persisted.count == 1)
        #expect(persisted[0].canonicalContent.localizedCaseInsensitiveContains("еспресо"))

        let context = await DefaultPersonalAIContextBuilder(store: reloaded).buildContext(
            PersonalAIContextRequest(surface: .g2Replies, userMessage: coffeePrompt)
        )
        #expect(context.relevantMemories.contains { $0.canonicalContent.localizedCaseInsensitiveContains("еспресо") })
    }

    // 31 — English path unchanged end-to-end
    @Test("English \"Remember that …\" still stores and retrieves after the Ukrainian fix")
    func englishStillWorksEndToEnd() async {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: "Remember that I'm building EvenAI for Even G2 smart glasses.",
            conversationID: UUID(), messageID: UUID(), store: store
        )
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "How is the EvenAI build going?")
        )
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("EvenAI"))
    }

    // 32 — Ukrainian rule reaches the rendered context on .g2Replies
    @Test("a Ukrainian \"Завжди …\" rule is an active rule in the built .g2Replies context")
    func ukrainianRuleInContext() async {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: "Завжди відповідай коротко.", conversationID: UUID(), messageID: UUID(), store: store
        )
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .g2Replies, userMessage: "Що відповісти клієнту?")
        )
        #expect(context.activeRules.contains { $0.text.localizedCaseInsensitiveContains("коротко") })
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("коротко"))
    }
}
