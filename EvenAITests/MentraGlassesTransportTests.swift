import Testing
@testable import EvenAI

/// Direct coverage of `MentraGlassesTransport.failureMessage(forCode:rawMessage:)`
/// — the Phase 2 fix for the `pairNeedDisconnect` failure mode — without
/// needing a real `MentraBluetoothSDK`/`CBCentralManager` instance.
@Suite("MentraGlassesTransport failure-message mapping")
struct MentraGlassesTransportTests {
    @Test("pair_failure is mapped to a clear, actionable message, not the SDK's raw internal slug")
    func pairFailureGetsCleanMessage() {
        let message = MentraGlassesTransport.failureMessage(
            forCode: "pair_failure",
            rawMessage: "errors:pairNeedDisconnect"
        )

        #expect(message != "errors:pairNeedDisconnect")
        #expect(message.contains("Bluetooth"))
    }

    @Test("any other failure code passes its message through unchanged")
    func otherFailuresPassThrough() {
        let message = MentraGlassesTransport.failureMessage(
            forCode: "bluetooth_powered_off",
            rawMessage: "Turn on phone Bluetooth to scan for glasses."
        )

        #expect(message == "Turn on phone Bluetooth to scan for glasses.")
    }
}

/// `GlassesTextPaginator` splits long chat replies into pages sized for
/// G2's fixed-size display — the fix for "long responses can't be
/// scrolled/read in full." Pure text logic, no SDK dependency.
@Suite("GlassesTextPaginator")
struct GlassesTextPaginatorTests {
    @Test("short text that fits on one page is returned completely unchanged — identical to pre-pagination behavior")
    func shortTextIsOnePageUnchanged() {
        let text = "Hello from EvenAI"
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 220)

        #expect(pages == [text])
    }

    @Test("long text is split into multiple pages")
    func longTextBecomesMultiplePages() {
        let text = Array(repeating: "word", count: 100).joined(separator: " ") // 499 characters
        // overlapWordCount: 0 isolates core-splitting size behavior from
        // the overlap feature (covered separately below) — with overlap
        // on, later pages are expected to exceed the raw budget by design.
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 50, overlapWordCount: 0)

        #expect(pages.count > 1)
        for page in pages {
            #expect(page.count <= 50)
        }
    }

    @Test("Unicode text (CJK, accents, a multi-scalar emoji grapheme cluster) is never corrupted or split mid-character")
    func unicodeTextIsNotCorrupted() {
        // "👨‍👩‍👧‍👦" is a single Character (one grapheme cluster) made of four
        // scalars joined by ZWJ — if pagination ever counted/split at the
        // Unicode-scalar or UTF-8-byte level instead of Character level,
        // this would come out broken.
        let text = "café 日本語のテスト 👨‍👩‍👧‍👦 more café text after the emoji to force a page break here"
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 20, overlapWordCount: 0)

        #expect(pages.count > 1)
        let familyEmoji = "👨‍👩‍👧‍👦"
        #expect(pages.contains { $0.contains(familyEmoji) })
        // Every character survives, in order, once whitespace differences
        // at page boundaries are normalized away.
        let rejoined = pages.joined()
        #expect(stripWhitespace(rejoined) == stripWhitespace(text))
    }

    @Test("page order is preserved: words come back in the same order they went in")
    func pageOrderIsPreserved() {
        let words = (0 ..< 40).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 30, overlapWordCount: 0)

        #expect(pages.count > 1)
        let reconstructedWords = pages.joined(separator: " ").split(separator: " ").map(String.init)
        #expect(reconstructedWords == words)
    }

    @Test("page boundaries never drop characters, even for a single word longer than the page budget")
    func boundariesDoNotDropCharacters() {
        // No whitespace at all within budget — forces the hard-break
        // fallback path (no word boundary to break on).
        let longWord = String(repeating: "a", count: 500)
        let text = "start \(longWord) end"
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 50, overlapWordCount: 0)

        #expect(pages.count > 1)
        #expect(stripWhitespace(pages.joined()) == stripWhitespace(text))
    }

    @Test("a realistic long paragraph loses no non-whitespace content across pages")
    func realisticParagraphPreservesAllContent() {
        let text = """
        This is a longer assistant reply that would not fit on the Even G2's small display \
        all at once, so it needs to be split across multiple pages that the user can swipe \
        through, without losing or reordering any part of the original response text.
        """
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 60, overlapWordCount: 0)

        #expect(pages.count > 1)
        #expect(stripWhitespace(pages.joined()) == stripWhitespace(text))
    }

    private func stripWhitespace(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

/// Coverage for the Phase 3 smoothness fix: no true scroll exists on G2
/// (verified against the vendored SDK — every text update is an instant
/// whole-container replace, and `updateTextMessage`'s `contentOffset`
/// field is always sent as `0`/full-length by the SDK itself, so there's
/// no scroll semantics to build on), so consecutive pages repeat a few
/// trailing words for reading continuity instead.
@Suite("GlassesTextPaginator overlap")
struct GlassesTextPaginatorOverlapTests {
    @Test("a page after the first starts with the last overlapWordCount words of the page before it")
    func consecutivePagesShareOverlappingWords() {
        let words = (0 ..< 40).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let noOverlap = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 30, overlapWordCount: 0)
        let withOverlap = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 30, overlapWordCount: 2)

        #expect(noOverlap.count == withOverlap.count) // overlap repeats content, never adds/removes pages
        for index in 1 ..< withOverlap.count {
            let expectedPrefix = noOverlap[index - 1]
                .split(whereSeparator: { $0.isWhitespace })
                .suffix(2)
                .joined(separator: " ")
            #expect(withOverlap[index].hasPrefix(expectedPrefix))
        }
    }

    @Test("the first page never gets an overlap prefix — there is nothing before it to repeat")
    func firstPageHasNoOverlapPrefix() {
        let words = (0 ..< 40).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let noOverlap = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 30, overlapWordCount: 0)
        let withOverlap = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 30, overlapWordCount: 2)

        #expect(withOverlap.first == noOverlap.first)
    }

    @Test("overlap does not apply when the text fits on a single page")
    func overlapDoesNothingForASinglePage() {
        let text = "Hello from EvenAI"
        let pages = GlassesTextPaginator.pages(for: text, maxCharactersPerPage: 220, overlapWordCount: 3)

        #expect(pages == [text])
    }

    @Test("the default call (no explicit parameters) produces overlapping pages for long text")
    func defaultsProduceOverlappingPagesForLongText() {
        let words = (0 ..< 200).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let pages = GlassesTextPaginator.pages(for: text) // all defaults

        #expect(pages.count > 1)
        // Page 2 must contain at least one word also present at the end of
        // page 1 — the overlap — proving the defaults actually wire
        // `defaultOverlapWordCount` through, not just `defaultMaxCharactersPerPage`.
        let lastWordOfPageOne = pages[0].split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
        #expect(lastWordOfPageOne != nil)
        #expect(pages[1].contains(lastWordOfPageOne!))
    }
}

/// `GlassesPaginationState` tracks which page of the current message is
/// showing and how swipe navigation moves through them. Pure state, no
/// SDK dependency — this is what makes "new message resets to page 1" and
/// "disconnect clears pagination state" testable at all, since
/// `MentraGlassesTransport.sendText`/`disconnect` themselves require a
/// real, connected SDK instance that can't be constructed in a unit test.
@Suite("GlassesPaginationState")
struct GlassesPaginationStateTests {
    @Test("start() begins at page 1")
    func startBeginsAtPageOne() {
        var state = GlassesPaginationState()
        state.start(withPages: ["page one", "page two", "page three"])

        #expect(state.currentPage == "page one")
    }

    @Test("advance() moves forward and returns the new page; retreat() moves back")
    func advanceAndRetreatMoveThroughPages() {
        var state = GlassesPaginationState()
        state.start(withPages: ["page one", "page two", "page three"])

        #expect(state.advance() == "page two")
        #expect(state.currentPage == "page two")
        #expect(state.advance() == "page three")
        #expect(state.retreat() == "page two")
        #expect(state.currentPage == "page two")
    }

    @Test("advance() past the last page and retreat() before the first page are no-ops")
    func navigationClampsAtBothEnds() {
        var state = GlassesPaginationState()
        state.start(withPages: ["only page"])

        #expect(state.advance() == nil)
        #expect(state.currentPage == "only page")
        #expect(state.retreat() == nil)
        #expect(state.currentPage == "only page")
    }

    @Test("a new message replaces any previous pagination and resets to page 1, even mid-navigation")
    func newMessageResetsToPageOne() {
        var state = GlassesPaginationState()
        state.start(withPages: ["old 1", "old 2", "old 3"])
        _ = state.advance() // now on "old 2" — simulates the user having swiped

        state.start(withPages: ["new 1", "new 2"])

        #expect(state.currentPage == "new 1")
        #expect(state.advance() == "new 2")
    }

    @Test("clear() empties pagination state, as on disconnect")
    func clearEmptiesState() {
        var state = GlassesPaginationState()
        state.start(withPages: ["page one", "page two"])
        _ = state.advance()

        state.clear()

        #expect(state.currentPage == nil)
        #expect(state.advance() == nil)
        #expect(state.retreat() == nil)
    }
}
