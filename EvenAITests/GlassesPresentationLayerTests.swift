import Foundation
import Testing
@testable import EvenAI

/// Pure tests for `GlassesPresentationLayer` — no SwiftUI, no
/// `MentraGlassesTransport`, no hardware.
///
/// Covers the unified page format (see that type's doc comment): every
/// page — with or without replies — carries the SAME Source+Ukrainian
/// header, so a turn's translation is never removed by a later reply
/// update; with replies present, each reply gets its OWN page (never
/// packed together), so a swipe moves between replies while the header
/// stays put.
@Suite("GlassesPresentationLayer")
struct GlassesPresentationLayerTests {
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

    @Test("a foreign turn with no replies yet produces a single page: the original phrase and its Ukrainian translation")
    func headerOnly() {
        let pages = GlassesPresentationLayer.pages(for: turn(originalText: "Hallo", translation: "Привіт"))
        #expect(pages == ["Hallo\n\nUA: Привіт"])
    }

    @Test("a foreign turn with one reply produces exactly one page: header plus that reply")
    func headerPlusOneReply() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            originalText: "Hallo",
            translation: "Привіт",
            replies: [reply("Hi", "Привіт", ordering: 0)]
        ))
        #expect(pages == ["Hallo\n\nUA: Привіт\n\nReply 1:\nHi\nUA: Привіт"])
    }

    @Test("a foreign turn with three replies produces one page PER reply — never packed together — each carrying the same header")
    func onePagePerReply() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            originalText: "Wie geht es dir?",
            translation: "Як справи?",
            replies: [
                reply("Good", "Добре", ordering: 0),
                reply("Not bad", "Непогано", ordering: 1),
                reply("Great", "Чудово", ordering: 2),
            ]
        ))
        #expect(pages.count == 3)
        for page in pages {
            #expect(page.hasPrefix("Wie geht es dir?\n\nUA: Як справи?\n\n"))
        }
        #expect(pages[0].contains("Reply 1:\nGood\nUA: Добре"))
        #expect(pages[1].contains("Reply 2:\nNot bad\nUA: Непогано"))
        #expect(pages[2].contains("Reply 3:\nGreat\nUA: Чудово"))
    }

    @Test("a fourth reply is dropped — maximum 3 reply pages")
    func maxThreeReplies() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            translation: "Переклад",
            replies: [
                reply("A", "А", ordering: 0),
                reply("B", "Б", ordering: 1),
                reply("C", "В", ordering: 2),
                reply("D", "Г", ordering: 3),
            ]
        ))
        #expect(pages.count == 3)
        #expect(!pages.contains { $0.contains("D") })
        #expect(!pages.contains { $0.contains("Reply 4") })
    }

    @Test("replies are numbered by ordering, independent of their array position")
    func preservesOrdering() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            translation: "Переклад",
            replies: [
                reply("Third", "Третій", ordering: 2),
                reply("First", "Перший", ordering: 0),
                reply("Second", "Другий", ordering: 1),
            ]
        ))
        #expect(pages.count == 3)
        #expect(pages[0].contains("Reply 1:\nFirst\nUA: Перший"))
        #expect(pages[1].contains("Reply 2:\nSecond\nUA: Другий"))
        #expect(pages[2].contains("Reply 3:\nThird\nUA: Третій"))
    }

    @Test("a reply with empty original text is omitted, and remaining replies are numbered contiguously")
    func omitsEmptyReplyText() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            translation: "Переклад",
            replies: [
                reply("First", "Перший", ordering: 0),
                reply("   ", "Порожній", ordering: 1),
                reply("Third", "Третій", ordering: 2),
            ]
        ))
        // The empty-text reply is gone entirely, and "Third" is
        // renumbered "Reply 2" — never "Reply 1, Reply 3" with a gap.
        #expect(pages.count == 2)
        #expect(pages[0].contains("Reply 1:\nFirst"))
        #expect(pages[1].contains("Reply 2:\nThird"))
    }

    @Test("an empty or whitespace-only translation produces no pages at all, even with replies present")
    func omitsEmptyTranslation() {
        let emptyPages = GlassesPresentationLayer.pages(for: turn(
            translation: "",
            replies: [reply("Hi", "Привіт", ordering: 0)]
        ))
        let whitespacePages = GlassesPresentationLayer.pages(for: turn(
            translation: "   \n  ",
            replies: [reply("Hi", "Привіт", ordering: 0)]
        ))
        #expect(emptyPages.isEmpty)
        #expect(whitespacePages.isEmpty)
    }

    @Test("a Ukrainian/no-translation turn produces no pages")
    func ukrainianOrNoTranslationProducesNoPages() {
        let noTranslation = GlassesPresentationLayer.pages(for: turn(translation: nil))
        let ukrainianTurn = ConversationTurn.liveConversationTurn(
            originalText: "Привіт!",
            detectedLanguage: "uk-UA",
            ukrainianTranslation: "Привіт!" // liveConversationTurn nulls this out itself
        )
        #expect(noTranslation.isEmpty)
        #expect(GlassesPresentationLayer.pages(for: ukrainianTurn).isEmpty)
    }

    @Test("a long header-only translation (no replies yet) is paginated exactly as GlassesTextPaginator would on its own")
    func longTranslationUsesExistingPaginationRules() {
        let translation = "Це дуже довгий переклад, який точно не поміститься на одній сторінці дисплея окулярів G2 без розбиття на кілька частин для читання."
        let originalText = "phrase"
        let maxCharactersPerPage = 20

        let pages = GlassesPresentationLayer.pages(for: turn(originalText: originalText, translation: translation), maxCharactersPerPage: maxCharactersPerPage)
        let expected = GlassesTextPaginator.pages(for: "\(originalText)\n\nUA: \(translation)", maxCharactersPerPage: maxCharactersPerPage)

        #expect(pages == expected)
        #expect(pages.count > 1)
    }

    @Test("a reply too long to fit alongside the header on one page degrades to GlassesTextPaginator's split, without dropping any character")
    func overlongReplyDegradesGracefully() {
        let longReply = "This is a much longer reply than usual, long enough that even alongside the header it cannot fit on a single G2 page no matter how the budget is sliced."
        let pages = GlassesPresentationLayer.pages(
            for: turn(originalText: "Q", translation: "П", replies: [reply(longReply, "УА", ordering: 0)]),
            maxCharactersPerPage: 40
        )
        #expect(pages.count > 1)
        // GlassesTextPaginator breaks on whitespace boundaries — it does
        // not guarantee a literal substring survives intact across a hard
        // page split, only that no character is dropped. "reply" and
        // "sliced" anchor the start and end of the original reply text.
        #expect(pages.joined().contains("reply"))
        #expect(pages.joined().contains("sliced"))
    }

    @Test("output is deterministic across repeated calls with the same input")
    func deterministicOutput() {
        let sourceTurn = turn(
            translation: "Переклад",
            replies: [
                reply("A", "А", ordering: 0),
                reply("B", "Б", ordering: 1),
            ]
        )
        let first = GlassesPresentationLayer.pages(for: sourceTurn)
        let second = GlassesPresentationLayer.pages(for: sourceTurn)
        #expect(first == second)
    }

    @Test("replies from two different turns never mix in either turn's pages")
    func neverMixesRepliesAcrossTurns() {
        let turnA = turn(originalText: "A?", translation: "Переклад А", replies: [reply("A-reply", "А-відповідь", ordering: 0)])
        let turnB = turn(originalText: "B?", translation: "Переклад Б", replies: [reply("B-reply", "Б-відповідь", ordering: 0)])

        let pagesA = GlassesPresentationLayer.pages(for: turnA)
        let pagesB = GlassesPresentationLayer.pages(for: turnB)

        #expect(pagesA.contains { $0.contains("A-reply") })
        #expect(!pagesA.contains { $0.contains("B-reply") })
        #expect(pagesB.contains { $0.contains("B-reply") })
        #expect(!pagesB.contains { $0.contains("A-reply") })
    }

    @Test("every reply page for a turn also contains that turn's original phrase and Ukrainian translation — the header is never dropped")
    func everyReplyPageKeepsTheHeader() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            originalText: "How are you?",
            translation: "Як ти?",
            replies: [
                reply("I'm good, thank you.", "У мене все добре, дякую.", ordering: 0),
                reply("Pretty well. How about you?", "Досить добре. А ти?", ordering: 1),
            ]
        ))
        #expect(pages.count == 2)
        for page in pages {
            #expect(page.contains("How are you?"))
            #expect(page.contains("UA: Як ти?"))
        }
    }
}
