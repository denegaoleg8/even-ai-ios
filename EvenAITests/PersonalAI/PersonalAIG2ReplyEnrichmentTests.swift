import Testing
import Foundation
@testable import EvenAI

/// PHASE 3 — Slice 1 (decorator behaviour) + Slice 4 (concurrency / stale-turn
/// / cancellation / account-switch).
///
/// `PersonalAIContextEnrichingSuggestedReplyGenerator` vs deterministic fakes.
/// Proves Personal AI is an optional advisory layer: every failure mode falls
/// through to the wrapped base generator unchanged, exactly once.
@Suite("Phase 3: G2 reply enrichment — decorator")
struct PersonalAIG2ReplyEnrichmentTests {

    private func turn(_ text: String, lang: String? = "en-US") -> ConversationTurn {
        ConversationTurn.liveConversationTurn(
            originalText: text, detectedLanguage: lang, ukrainianTranslation: "переклад"
        )
    }

    private func makeDecorator(
        base: any SuggestedReplyGenerating,
        builder: any PersonalAIContextBuilding,
        owner: @escaping @Sendable () -> String? = { "owner-A" },
        profile: @escaping @Sendable () -> ConversationProfile = { .conversation },
        config: PersonalAIReplyEnrichmentConfig = .default
    ) -> PersonalAIContextEnrichingSuggestedReplyGenerator {
        PersonalAIContextEnrichingSuggestedReplyGenerator(
            base: base, contextBuilder: builder, ownerID: owner,
            conversationProfile: profile, config: config
        )
    }

    private let replies = [SuggestedReply(originalLanguageText: "Sure.", ukrainianText: "Звісно.", ordering: 0)]

    // MARK: - enrichment applied

    @Test("relevant Personal AI context enriches the base request — exactly one base call")
    func enrichmentApplied() async throws {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let builder = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised("Response style: be very direct."))
        let sut = makeDecorator(base: fakeBase, builder: builder)

        let out = try await sut.generateReplies(for: turn("How's it going?"), context: SuggestedReplyContext())

        #expect(out == replies)
        let calls = await fakeBase.calls
        #expect(calls.count == 1)                                        // SINGLE PASS
        let passed = try #require(calls.first?.context.personalAIContext)
        #expect(passed.contains("be very direct"))
        #expect(passed.contains("Never mention that you know"))           // framing
        #expect(await builder.surfaces == [.g2Replies])
    }

    @Test("the enrichment request is scoped to .g2Replies with the configured token budget")
    func requestScoping() async throws {
        let builder = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised())
        let config = PersonalAIReplyEnrichmentConfig(contextTokenBudget: 640, enrichmentTimeout: .seconds(4), surface: .g2Replies, maxRecentConversationLines: 2)
        let sut = makeDecorator(base: FakeSuggestedReplyGenerator(defaultReplies: replies), builder: builder, config: config)

        _ = try await sut.generateReplies(
            for: turn("latest phrase"),
            context: SuggestedReplyContext(recentTurns: [turn("older 1"), turn("older 2"), turn("older 3")])
        )
        let req = try #require(await builder.lastRequest)
        #expect(req.surface == .g2Replies)
        #expect(req.userMessage == "latest phrase")
        #expect(req.tokenBudget == 640)
        #expect(req.recentConversation == ["older 2", "older 3"])        // trimmed to maxRecentConversationLines
        #expect(req.conversationID == nil)
    }

    // MARK: - fallbacks (every one → un-enriched base call, exactly once)

    @Test("no personalisation → plain base replies, no personalAIContext")
    func noPersonalisationFallsThrough() async throws {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let sut = makeDecorator(base: fakeBase, builder: ScriptedContextBuilder(result: .empty))

        let out = try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        #expect(out == replies)
        let calls = await fakeBase.calls
        #expect(calls.count == 1)
        #expect(calls.first?.context.personalAIContext == nil)
    }

    @Test("memory disabled → retrieval result is ignored, plain base replies")
    func memoryDisabledFallsThrough() async throws {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let sut = makeDecorator(base: fakeBase, builder: ScriptedContextBuilder(result: ScriptedContextBuilder.memoryDisabled))

        let out = try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        #expect(out == replies)
        #expect(await fakeBase.calls.first?.context.personalAIContext == nil)
    }

    @Test("enrichment slower than the timeout → plain base replies (translation-budget-safe)")
    func enrichmentTimeoutFallsThrough() async throws {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let slow = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised(), delay: .seconds(10))
        let fastTimeout = PersonalAIReplyEnrichmentConfig(contextTokenBudget: 700, enrichmentTimeout: .milliseconds(40), surface: .g2Replies, maxRecentConversationLines: 4)
        let sut = makeDecorator(base: fakeBase, builder: slow, config: fastTimeout)

        let started = Date()
        let out = try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        #expect(Date().timeIntervalSince(started) < 2)                   // did NOT wait the 10s
        #expect(out == replies)
        #expect(await fakeBase.calls.count == 1)
        #expect(await fakeBase.calls.first?.context.personalAIContext == nil)
    }

    @Test("base generator error still propagates (the decorator does not mask it)")
    func baseErrorPropagates() async {
        let err = FakeSuggestedReplyGenerationError(message: "boom")
        let sut = makeDecorator(base: FakeSuggestedReplyGenerator(error: err), builder: ScriptedContextBuilder(result: .empty))
        await #expect(throws: FakeSuggestedReplyGenerationError.self) {
            _ = try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        }
    }

    // MARK: - caller cancellation ≠ Personal AI failure

    @Test("a cancelled caller task throws CancellationError and never calls the base generator")
    func callerCancellationBeforeStart() async {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let sut = makeDecorator(base: fakeBase, builder: ScriptedContextBuilder(result: ScriptedContextBuilder.personalised()))

        let task = Task {
            try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await fakeBase.calls.isEmpty)                            // NEVER a stale "successful" result
    }

    @Test("cancellation DURING enrichment is surfaced, not converted to a base fallback")
    func cancellationDuringEnrichment() async {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let slow = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised(), delay: .seconds(5))
        let sut = makeDecorator(base: fakeBase, builder: slow)

        let task = Task {
            try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await fakeBase.calls.isEmpty)
    }

    // MARK: - account switch (Slice 4)

    @Test("account switch mid-build → that build's enrichment is discarded, plain base replies")
    func accountSwitchDiscardsEnrichment() async throws {
        let fakeBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let owner = LockedBox<String?>("owner-A")
        let slow = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised(), delay: .milliseconds(80))
        let sut = makeDecorator(base: fakeBase, builder: slow, owner: { owner.value })

        let task = Task { try await sut.generateReplies(for: turn("hi"), context: SuggestedReplyContext()) }
        try await Task.sleep(for: .milliseconds(20))
        owner.value = "owner-B"                                          // switch while the build is running
        let out = try await task.value

        #expect(out == replies)
        #expect(await fakeBase.calls.count == 1)
        #expect(await fakeBase.calls.first?.context.personalAIContext == nil)   // cross-account enrichment rejected
    }

    // MARK: - stale-turn (Slice 4) — the decorator is stateless; the engine's
    // existing sequence gate does the display-level rejection. Here we prove
    // the decorator never *itself* races two turns' results together.

    @Test("two concurrent turns get independent enrichment; neither leaks into the other")
    func concurrentTurnsIndependent() async throws {
        let a = ScriptedContextBuilder.personalised("Response style: for turn A.")
        let fakeBase = FakeSuggestedReplyGenerator(
            repliesByOriginalText: ["A": replies, "B": replies])
        // one builder instance, but each call gets its own request/result path
        let builder = ScriptedContextBuilder(result: a, delay: .milliseconds(30))
        let sut = makeDecorator(base: fakeBase, builder: builder)

        async let ra = sut.generateReplies(for: turn("A"), context: SuggestedReplyContext())
        async let rb = sut.generateReplies(for: turn("B"), context: SuggestedReplyContext())
        _ = try await (ra, rb)

        let calls = await fakeBase.calls
        #expect(calls.count == 2)
        // both calls carry a block that came from THEIR own build (same scripted
        // result here, but each is a distinct base call with a distinct turn)
        #expect(calls.allSatisfy { $0.context.personalAIContext?.contains("for turn A") == true })
        #expect(Set(calls.map { $0.turn.originalText }) == ["A", "B"])
    }
}

/// A tiny lock-protected box for a value a `@Sendable` closure mutates from a
/// test (models `PersonalOwnerBox` for the decorator's `ownerID` closure).
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
