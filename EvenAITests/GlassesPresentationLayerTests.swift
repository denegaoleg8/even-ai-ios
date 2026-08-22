import Foundation
import Testing
@testable import EvenAI

/// Pure tests for `GlassesPresentationLayer` — no SwiftUI, no
/// `MentraGlassesTransport`, no hardware. Milestone 5 is this file plus
/// the implementation; nothing here is wired to real G2 sending yet.
@Suite("GlassesPresentationLayer")
struct GlassesPresentationLayerTests {
    private func reply(_ original: String, _ ukrainian: String, ordering: Int) -> SuggestedReply {
        SuggestedReply(originalLanguageText: original, ukrainianText: ukrainian, ordering: ordering)
    }

    private func turn(
        translation: String?,
        replies: [SuggestedReply] = [],
        detectedLanguage: String? = "en-US"
    ) -> ConversationTurn {
        ConversationTurn(
            originalText: "original phrase",
            detectedLanguage: detectedLanguage,
            ukrainianTranslation: translation,
            suggestedReplies: replies,
            source: .liveConversation
        )
    }

    @Test("a foreign turn with no replies produces the translation page only")
    func translationOnly() {
        let pages = GlassesPresentationLayer.pages(for: turn(translation: "Привіт"))
        #expect(pages == ["Привіт"])
    }

    @Test("a foreign turn with one reply produces the translation page plus one reply page")
    func translationPlusOneReply() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            translation: "Привіт",
            replies: [reply("Hi", "Привіт", ordering: 0)]
        ))
        #expect(pages == ["Привіт", "1. Hi\nПривіт"])
    }

    @Test("a foreign turn with three short replies packs them onto one reply page")
    func translationPlusThreeReplies() {
        let pages = GlassesPresentationLayer.pages(for: turn(
            translation: "Переклад",
            replies: [
                reply("A", "А", ordering: 0),
                reply("B", "Б", ordering: 1),
                reply("C", "В", ordering: 2),
            ]
        ))
        #expect(pages == ["Переклад", "1. A\nА\n\n2. B\nБ\n\n3. C\nВ"])
    }

    @Test("a fourth reply is dropped — maximum 3 replies")
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
        #expect(pages == ["Переклад", "1. A\nА\n\n2. B\nБ\n\n3. C\nВ"])
        #expect(!(pages.last ?? "").contains("D"))
        #expect(!(pages.last ?? "").contains("4."))
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
        #expect(pages == ["Переклад", "1. First\nПерший\n\n2. Second\nДругий\n\n3. Third\nТретій"])
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
        // renumbered "2." — never "1., 3." with a gap.
        #expect(pages == ["Переклад", "1. First\nПерший\n\n2. Third\nТретій"])
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

    @Test("a long translation is paginated exactly as GlassesTextPaginator would on its own")
    func longTranslationUsesExistingPaginationRules() {
        let translation = "Це дуже довгий переклад, який точно не поміститься на одній сторінці дисплея окулярів G2 без розбиття на кілька частин для читання."
        let maxCharactersPerPage = 20

        let pages = GlassesPresentationLayer.pages(for: turn(translation: translation), maxCharactersPerPage: maxCharactersPerPage)
        let expected = GlassesTextPaginator.pages(for: translation, maxCharactersPerPage: maxCharactersPerPage)

        #expect(pages == expected)
        #expect(pages.count > 1)
    }

    @Test("a reply and its Ukrainian meaning always stay on the same page together, even when replies span multiple pages")
    func replyPairsStayTogetherAcrossPages() {
        let replies = [
            reply("Sure, that works for me.", "Так, мені підходить.", ordering: 0),
            reply("Could we do Thursday instead?", "Можемо натомість у четвер?", ordering: 1),
            reply("Let me check and get back to you.", "Дай перевірю і скажу.", ordering: 2),
        ]
        // Large enough that every individual block (the longest is ~59
        // characters) fits on a page by itself — so this never triggers
        // the rare single-block-too-long-for-any-page fallback, which is
        // the one case allowed to split a pair — while still being too
        // small for any two blocks to share a page, forcing the packing
        // logic to actually split across pages.
        let maxCharactersPerPage = 65

        let pages = GlassesPresentationLayer.pages(for: turn(translation: "Переклад", replies: replies), maxCharactersPerPage: maxCharactersPerPage)

        #expect(pages.count == 4) // translation page + one reply page per block

        for page in pages.dropFirst() {
            if page.contains("1. Sure, that works for me.") {
                #expect(page.contains("Так, мені підходить."))
            }
            if page.contains("2. Could we do Thursday instead?") {
                #expect(page.contains("Можемо натомість у четвер?"))
            }
            if page.contains("3. Let me check and get back to you.") {
                #expect(page.contains("Дай перевірю і скажу."))
            }
        }
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
        let turnA = turn(translation: "Переклад А", replies: [reply("A-reply", "А-відповідь", ordering: 0)])
        let turnB = turn(translation: "Переклад Б", replies: [reply("B-reply", "Б-відповідь", ordering: 0)])

        let pagesA = GlassesPresentationLayer.pages(for: turnA)
        let pagesB = GlassesPresentationLayer.pages(for: turnB)

        #expect(pagesA.contains { $0.contains("A-reply") })
        #expect(!pagesA.contains { $0.contains("B-reply") })
        #expect(pagesB.contains { $0.contains("B-reply") })
        #expect(!pagesB.contains { $0.contains("A-reply") })
    }
}
