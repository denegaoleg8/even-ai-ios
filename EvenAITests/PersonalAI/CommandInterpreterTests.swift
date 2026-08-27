import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: command interpretation & application")
struct CommandInterpreterTests {

    private func freshStore() -> InMemoryPersonalMemoryStore { InMemoryPersonalMemoryStore() }

    // MARK: Scenario 1 — explicit remember command

    @Test("'remember that…' creates a memory")
    func rememberCreatesMemory() async {
        let store = freshStore()
        let processor = MemoryCommandProcessor()
        let outcomes = await processor.process(
            message: "Remember that I'm building EvenAI for G2 glasses.",
            conversationID: UUID(), messageID: UUID(), store: store
        )
        #expect(outcomes.contains { if case .remembered = $0.kind { return true } else { return false } })
        let memories = await store.allMemories()
        #expect(memories.count == 1)
        #expect(memories[0].canonicalContent.localizedCaseInsensitiveContains("EvenAI"))
        #expect(memories[0].userConfirmed)
        #expect(memories[0].category == .projects)
    }

    @Test("remember works without exact wording")
    func rememberVariants() {
        let interpreter = CommandInterpreter()
        for phrasing in [
            "remember I prefer dark mode",
            "keep in mind that the office is closed on Fridays",
            "note that Andrii is my co-founder",
            "don't forget my dentist appointment is important",
        ] {
            let commands = interpreter.interpret(phrasing)
            #expect(commands.contains { if case .remember = $0 { return true } else { return false } }, "failed for: \(phrasing)")
        }
    }

    // MARK: Scenario 2 — from-now-on creates/updates a rule

    @Test("'from now on…' creates a rule")
    func fromNowOnCreatesRule() async {
        let store = freshStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: "From now on, keep business replies short.", conversationID: UUID(), messageID: UUID(), store: store)
        let rules = await store.allRules()
        #expect(rules.count == 1)
        #expect(rules[0].text.localizedCaseInsensitiveContains("short"))
        #expect(rules[0].enabled)
        #expect(rules[0].priority == .activeRule)
    }

    @Test("'always' / 'never' create rules; a repeat updates rather than duplicates")
    func alwaysNeverRules() async {
        let store = freshStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: "Never open a reply with 'thanks for sharing'.", conversationID: UUID(), messageID: UUID(), store: store)
        _ = await processor.process(message: "Never open a reply with 'thanks for sharing'.", conversationID: UUID(), messageID: UUID(), store: store)
        let rules = await store.allRules()
        #expect(rules.count == 1)
        #expect(rules[0].text.localizedCaseInsensitiveContains("never"))
    }

    // MARK: Scenario 3 — forget removes/disables the right memory

    @Test("'forget…' archives the matching memory and leaves the others")
    func forgetArchivesRightMemory() async {
        let store = freshStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: "Remember that I live in Kyiv.", conversationID: UUID(), messageID: UUID(), store: store)
        _ = await processor.process(message: "Remember that I prefer tea over coffee.", conversationID: UUID(), messageID: UUID(), store: store)

        let outcomes = await processor.process(message: "Forget that I prefer tea over coffee.", conversationID: UUID(), messageID: UUID(), store: store)
        #expect(outcomes.contains { if case .forgotten = $0.kind { return true } else { return false } })

        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.count == 1)
        #expect(active[0].canonicalContent.localizedCaseInsensitiveContains("Kyiv"))

        let all = await store.allMemories()
        let tea = all.first { $0.canonicalContent.localizedCaseInsensitiveContains("tea") }
        #expect(tea?.status == .archived)
        #expect(tea?.enabled == false)
    }

    @Test("'forget…' with no match reports it, changes nothing")
    func forgetNoMatch() async {
        let store = freshStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: "Remember that I live in Kyiv.", conversationID: UUID(), messageID: UUID(), store: store)
        let outcomes = await processor.process(message: "Forget about my favourite colour.", conversationID: UUID(), messageID: UUID(), store: store)
        #expect(outcomes.contains { $0.kind == .noMatchToForget })
        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.count == 1)
    }

    @Test("a plain statement is not a command")
    func plainStatementIsNotACommand() {
        let interpreter = CommandInterpreter()
        #expect(interpreter.interpret("I had a good meeting with the team today").isEmpty)
        #expect(interpreter.interpret("What do you think about the launch date?").isEmpty)
    }
}
