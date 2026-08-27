import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: security foundations")
struct PersonalAISecurityTests {

    // MARK: Scenario 19 — secrets / credentials rejected from memory

    @Test("credential-looking content is never stored via a remember command")
    func secretRejectedFromRememberCommand() async {
        let store = InMemoryPersonalMemoryStore()
        let outcomes = await MemoryCommandProcessor().process(
            message: "Remember my OpenAI key is sk-abc123def456ghi789jkl012mno345",
            conversationID: UUID(), messageID: UUID(), store: store
        )
        #expect(outcomes.contains { $0.kind == .rejectedSecret })
        let memories = await store.allMemories()
        #expect(memories.isEmpty)
    }

    @Test("the extractor drops an exchange containing a secret")
    func secretRejectedFromExtractor() async {
        let candidates = await HeuristicMemoryExtractor().extract(
            from: .user("my password is hunter2hunter2 and I live in Kyiv"),
            existing: [], excludedConversationIDs: [], memoryEnabled: true
        )
        #expect(candidates.isEmpty)
    }

    @Test("the merger rejects a secret candidate outright")
    func mergerRejectsSecret() {
        let candidate = MemoryCandidate(
            record: MemoryRecord(category: .knowledge, canonicalContent: "AWS key AKIAIOSFODNN7EXAMPLE for the deploy bucket"),
            rationale: "test"
        )
        guard case .reject = MemoryMerger().reconcile(candidate: candidate, against: []) else {
            Issue.record("expected .reject")
            return
        }
    }

    @Test("manual Memory Center add rejects a secret")
    @MainActor
    func manualAddRejectsSecret() async {
        let store = InMemoryPersonalMemoryStore()
        let service = PersonalAIService(store: store, contextBuilder: DefaultPersonalAIContextBuilder(store: store), modelProvider: FakePersonalAIModelProvider(), conversationStore: InMemoryPersonalAIConversationStore())
        let ok = await service.addManualMemory(content: "github token ghp_1234567890abcdefghijklmnopqrstuvwx", category: .knowledge)
        #expect(ok == false)
        let memories = await store.allMemories()
        #expect(memories.isEmpty)
    }

    // MARK: Scenario 20 — raw memory absent from diagnostic logs

    @Test("no memory content or secret reaches stdout / diagnostic traces")
    @MainActor
    func rawMemoryAbsentFromLogs() async {
        let distinctiveContent = "ZebraQuokkaMarmoset the launch is in Novembruary"
        let distinctiveSecret = "sk-ZZZdistinctiveSecretValue0000000000"
        let store = InMemoryPersonalMemoryStore()
        let service = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: FakePersonalAIModelProvider(reply: "ack"),
            conversationStore: InMemoryPersonalAIConversationStore()
        )

        let captured = await StdoutCapture.capture {
            await service.open()
            await service.send("Remember that \(distinctiveContent).")
            await service.send("Also remember my key is \(distinctiveSecret).")
            _ = await service.loadMemories()
        }

        #expect(captured.contains(distinctiveContent) == false, "memory content leaked into logs")
        #expect(captured.contains(distinctiveSecret) == false, "secret leaked into logs")
        #expect(captured.contains("ZebraQuokkaMarmoset") == false)
    }
}

/// Captures everything written to `stdout` (which is what `DiagnosticTrace`
/// uses via `print`) during an async closure.
enum StdoutCapture {
    @MainActor
    static func capture(_ body: @MainActor () async -> Void) async -> String {
        let pipe = Pipe()
        let original = dup(fileno(stdout))
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))

        await body()

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(original, fileno(stdout))
        close(original)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
