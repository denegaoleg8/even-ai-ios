import Testing
@testable import EvenAI

/// Pure tests for `GlassesChatMessageContent.parse(_:)` — the parser
/// `MessageBubbleView` uses to render a Glasses Chat turn's source phrase
/// and Ukrainian translation as clearly separated rows instead of one
/// flat paragraph (Section F, "focused usability/performance cleanup").
@Suite("GlassesChatMessageContent")
struct GlassesChatMessageContentTests {
    @Test("parses a well-formed Glasses Chat turn into source + translation")
    func parsesWellFormedTurn() {
        let parsed = GlassesChatMessageContent.parse("Guten Tag\n→ Добрий день")
        #expect(parsed?.source == "Guten Tag")
        #expect(parsed?.translation == "Добрий день")
    }

    @Test("a normal Chat message with no separator falls back to nil (plain rendering)")
    func plainMessageIsNotParsed() {
        #expect(GlassesChatMessageContent.parse("What's the weather in Tokyo?") == nil)
    }

    @Test("a message containing the separator more than once is rejected rather than mis-split")
    func multipleSeparatorsRejected() {
        #expect(GlassesChatMessageContent.parse("A\n→ B\n→ C") == nil)
    }

    @Test("empty source or translation after trimming is rejected")
    func emptyPartsRejected() {
        #expect(GlassesChatMessageContent.parse("\n→ Добрий день") == nil)
        #expect(GlassesChatMessageContent.parse("Guten Tag\n→ ") == nil)
        #expect(GlassesChatMessageContent.parse("   \n→    ") == nil)
    }

    @Test("leading/trailing whitespace on either side is trimmed")
    func trimsWhitespace() {
        let parsed = GlassesChatMessageContent.parse("  Guten Tag  \n→   Добрий день  ")
        #expect(parsed?.source == "Guten Tag")
        #expect(parsed?.translation == "Добрий день")
    }
}
