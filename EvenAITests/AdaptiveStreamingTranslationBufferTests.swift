import Testing
import Foundation
@testable import EvenAI

/// Pure tests for `AdaptiveStreamingTranslationBuffer` — entirely driven
/// by explicit `now:` timestamps, no real async waiting, no
/// `LiveTranslationService` involved. See that type's own doc comment
/// for the full chunk-boundary design this verifies.
@Suite("AdaptiveStreamingTranslationBuffer")
struct AdaptiveStreamingTranslationBufferTests {
    private let utteranceID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test("a brand-new utterance with its first partial does not fire immediately — no punctuation, no elapsed pause yet")
    func firstPartialDoesNotFireImmediately() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        let decision = buffer.receivePartial("I", now: epoch)
        #expect(decision == .wait)
    }

    /// The literal "word-by-word" regression guard: a rapid sequence of
    /// growing partials, each arriving well within the 350ms stability
    /// window and with no punctuation, must never produce a `.ready`
    /// decision — this is exactly the bug where "Як...", "Як ти...", "Як
    /// ти збираєшся..." each fired their own translation call.
    @Test("rapid successive partial growth with no punctuation and no real pause never fires a chunk")
    func rapidGrowthWithoutPauseNeverFires() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        let words = ["I", "I want", "I want to", "I want to go", "I want to go to", "I want to go to Berlin"]
        var decisions: [AdaptiveStreamingTranslationBuffer.Decision] = []
        for (index, text) in words.enumerated() {
            // 80ms apart — comfortably under the 350ms stability window,
            // modeling fast continuous speech's own partial cadence.
            let now = epoch.addingTimeInterval(Double(index) * 0.08)
            decisions.append(buffer.receivePartial(text, now: now))
        }

        #expect(decisions.allSatisfy { $0 == .wait })
    }

    @Test("text ending in punctuation fires a chunk immediately, without waiting for stability or the latency budget")
    func punctuationFiresImmediately() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        // Arrives almost instantly after the utterance began — nowhere
        // near the 350ms stability window or the 900ms budget.
        let now = epoch.addingTimeInterval(0.05)
        let decision = buffer.receivePartial("Where are you going?", now: now)

        #expect(decision == .ready(text: "Where are you going?", revision: 1))
    }

    @Test("a natural pause (350ms of no new text) fires a chunk via tick(now:), even with no punctuation")
    func pauseFiresViaTick() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        _ = buffer.receivePartial("Hello there", now: epoch)
        // A tick before the stability window has elapsed: still waiting.
        #expect(buffer.tick(now: epoch.addingTimeInterval(0.2)) == .wait)
        // A tick past the 350ms stability window: ready.
        let decision = buffer.tick(now: epoch.addingTimeInterval(0.4))
        #expect(decision == .ready(text: "Hello there", revision: 1))
    }

    @Test("the maximum latency budget (900ms) eventually flushes buffered speech even with no punctuation and no true pause")
    func maxLatencyBudgetFlushes() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        // Continuous growth every 100ms — never quite reaching the 350ms
        // stability window on its own — for a full second.
        var lastDecision: AdaptiveStreamingTranslationBuffer.Decision = .wait
        var text = "word"
        for i in 1...10 {
            text += " word\(i)"
            let now = epoch.addingTimeInterval(Double(i) * 0.1)
            lastDecision = buffer.receivePartial(text, now: now)
            if case .ready = lastDecision { break }
        }

        guard case .ready(let readyText, let revision) = lastDecision else {
            Issue.record("expected the max-latency budget to force a chunk within ~900ms of continuous growth")
            return
        }
        #expect(readyText == text)
        #expect(revision == 1)
    }

    @Test("for continuous fast speech with no pauses, chunks arrive roughly every ~0.9s (the latency budget), not once per word")
    func continuousFastSpeechChunksPeriodically() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        var readyCount = 0
        var text = ""
        // 30 words, 100ms apart (3 seconds of continuous fast speech,
        // never pausing long enough for stability to fire on its own).
        for i in 1...30 {
            text += (text.isEmpty ? "" : " ") + "word\(i)"
            let now = epoch.addingTimeInterval(Double(i) * 0.1)
            if case .ready = buffer.receivePartial(text, now: now) {
                readyCount += 1
            }
        }

        // 3 seconds / ~0.9s budget ≈ 3-4 chunks — nowhere near "one
        // request per word" (which would be 30).
        #expect(readyCount >= 2)
        #expect(readyCount <= 5)
    }

    @Test("revision increments monotonically across successive chunks of the same utterance")
    func revisionIncrementsAcrossChunks() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        let first = buffer.receivePartial("First clause,", now: epoch)
        guard case .ready(_, let firstRevision) = first else {
            Issue.record("expected punctuation to fire the first chunk")
            return
        }
        #expect(firstRevision == 1)

        let second = buffer.receivePartial("First clause, and a second one.", now: epoch.addingTimeInterval(0.05))
        guard case .ready(_, let secondRevision) = second else {
            Issue.record("expected punctuation to fire the second chunk")
            return
        }
        #expect(secondRevision == 2)
    }

    @Test("identical text (no new content) never re-fires, even past the stability window")
    func unchangedTextNeverRefires() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)

        let first = buffer.receivePartial("Hello.", now: epoch)
        #expect(first == .ready(text: "Hello.", revision: 1))

        // Same text again, well past the stability window — nothing new
        // to chunk.
        let second = buffer.tick(now: epoch.addingTimeInterval(1.0))
        #expect(second == .wait)
    }

    @Test("beginUtterance(id:now:) resets revision and lets a new utterance's own punctuation fire at revision 1 again")
    func newUtteranceResetsRevision() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        buffer.beginUtterance(id: utteranceID, now: epoch)
        let first = buffer.receivePartial("First utterance.", now: epoch)
        #expect(first == .ready(text: "First utterance.", revision: 1))

        let secondUtteranceID = UUID()
        buffer.endUtterance()
        buffer.beginUtterance(id: secondUtteranceID, now: epoch.addingTimeInterval(2))
        let second = buffer.receivePartial("Second utterance.", now: epoch.addingTimeInterval(2))
        #expect(second == .ready(text: "Second utterance.", revision: 1))
        #expect(buffer.utteranceID == secondUtteranceID)
    }

    @Test("tick(now:) before any utterance has begun is a harmless no-op")
    func tickBeforeUtteranceIsNoOp() {
        var buffer = AdaptiveStreamingTranslationBuffer()
        #expect(buffer.tick(now: epoch) == .wait)
    }
}
