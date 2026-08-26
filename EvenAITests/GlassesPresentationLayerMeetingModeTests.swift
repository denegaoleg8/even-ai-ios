import Foundation
import Testing
@testable import EvenAI

/// `GlassesPresentationLayer.meetingPages(for:)`/`meetingConversationPages(for:previousTurn:)`
/// — Meeting Mode's restored "replies must ALSO exist" behavior (suggested
/// replies were previously fully suppressed from G2 in Meeting Mode; now
/// they're reachable, without ever displacing what's actively shown).
/// Mirrors `GlassesPresentationLayerTests`' own fixture helpers.
@Suite("GlassesPresentationLayer — Meeting Mode replies")
struct GlassesPresentationLayerMeetingModeTests {
    private func reply(_ original: String, _ ukrainian: String, ordering: Int) -> SuggestedReply {
        SuggestedReply(originalLanguageText: original, ukrainianText: ukrainian, ordering: ordering)
    }

    private func turn(
        originalText: String = "original phrase",
        translation: String?,
        replies: [SuggestedReply] = [],
        detectedLanguage: String? = "en-US"
    ) -> ConversationTurn {
        ConversationTurn(
            originalText: originalText,
            detectedLanguage: detectedLanguage,
            ukrainianTranslation: translation,
            suggestedReplies: replies,
            source: .liveConversation
        )
    }

    @Test("no replies yet: identical to pages(for:) — header alone")
    func headerOnlyMatchesStandard() {
        let t = turn(originalText: "Hallo", translation: "Привіт")
        #expect(GlassesPresentationLayer.meetingPages(for: t) == GlassesPresentationLayer.pages(for: t))
        #expect(GlassesPresentationLayer.meetingPages(for: t) == ["Hallo\n\nUA: Привіт"])
    }

    @Test("with replies: page 0 is the PLAIN header — never merged with the first reply the way Standard Mode's pages(for:) does")
    func page0StaysPlainHeaderWithReplies() {
        let t = turn(
            originalText: "Hallo",
            translation: "Привіт",
            replies: [reply("Hi", "Привіт", ordering: 0)]
        )
        let pages = GlassesPresentationLayer.meetingPages(for: t)
        // Standard mode's own pages(for:) merges header+reply onto page 0
        // — the whole point of the Meeting Mode variant is that this does
        // NOT happen, so the two must differ here.
        #expect(pages != GlassesPresentationLayer.pages(for: t))
        #expect(pages.first == "Hallo\n\nUA: Привіт")
    }

    @Test("with replies: reply pages ARE present, appended after the header — reachable, not suppressed")
    func replyPagesArePresentAfterHeader() {
        let t = turn(
            originalText: "Wie geht es dir?",
            translation: "Як справи?",
            replies: [
                reply("Gut, danke", "Добре, дякую", ordering: 0),
                reply("Nicht so gut", "Не дуже добре", ordering: 1),
            ]
        )
        let pages = GlassesPresentationLayer.meetingPages(for: t)
        #expect(pages.count == 3) // header + 2 reply pages
        #expect(pages[0] == "Wie geht es dir?\n\nUA: Як справи?")
        #expect(pages[1].contains("Reply 1:") && pages[1].contains("Gut, danke") && pages[1].contains("UA: Добре, дякую"))
        #expect(pages[2].contains("Reply 2:") && pages[2].contains("Nicht so gut"))
        // Every page still carries the header — same invariant Standard
        // Mode's pages(for:) guarantees, for the same reason (a swipe
        // must never lose the translation).
        #expect(pages.allSatisfy { $0.contains("Wie geht es dir?") && $0.contains("UA: Як справи?") })
    }

    @Test("at most 3 reply pages, same cap as Standard Mode")
    func cappedAtThreeReplies() {
        let t = turn(
            translation: "переклад",
            replies: (0..<5).map { reply("reply \($0)", "відповідь \($0)", ordering: $0) }
        )
        let pages = GlassesPresentationLayer.meetingPages(for: t)
        #expect(pages.count == 4) // header + 3 replies (2 dropped)
    }

    @Test("meetingConversationPages appends one bounded look-back page, same as conversationPages")
    func historyContextAppended() {
        let previous = turn(originalText: "earlier phrase", translation: "раніший переклад")
        let current = turn(originalText: "Hallo", translation: "Привіт", replies: [reply("Hi", "Привіт", ordering: 0)])
        let pages = GlassesPresentationLayer.meetingConversationPages(for: current, previousTurn: previous)
        #expect(pages.count == 3) // header + 1 reply + history context
        #expect(pages.last?.hasPrefix("Previous:\n") == true)
        #expect(pages.last?.contains("earlier phrase") == true)
    }

    @Test("no translation yet: no pages at all, same as pages(for:)")
    func noTranslationProducesNoPages() {
        #expect(GlassesPresentationLayer.meetingPages(for: turn(translation: nil)) == [])
        #expect(GlassesPresentationLayer.meetingConversationPages(for: turn(translation: nil), previousTurn: nil) == [])
    }
}
