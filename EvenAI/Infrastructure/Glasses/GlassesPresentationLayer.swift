import Foundation

/// Converts one `ConversationTurn` into the ordered pages G2 should show
/// — pure, deterministic, and reuses `GlassesTextPaginator` (below, in
/// `MentraGlassesTransport.swift`) for the same character-budget rules
/// already applied to everything else G2 displays, rather than inventing
/// a second set of size constants. This is the sole reason it lives in
/// `Infrastructure/Glasses` rather than `Core/Domain`: it depends on
/// `GlassesTextPaginator`, and the Dependency Rule (`ARCHITECTURE.md`)
/// only allows that dependency direction, not the reverse.
///
/// NOT wired to `MentraGlassesTransport`/`sendText` yet — that's
/// Milestone 6; this type never imports/references either, and produces
/// exactly the `[String]` shape `GlassesPaginationState.start(withPages:)`
/// already accepts unchanged, so no adapter should be needed when that
/// wiring happens.
///
/// Page 1 (and any overflow pages `GlassesTextPaginator` itself
/// produces) is the Ukrainian translation alone — nothing else ever
/// shares that page, so it stays visually distinct from the suggested
/// replies that follow. Every subsequent page packs one or more numbered
/// reply + Ukrainian-meaning blocks; a block is never split across a
/// page boundary except in the rare case a single reply is, on its own,
/// too long to fit on any page at all — an edge case the product's own
/// "replies must be short enough for G2" requirement makes uncommon, not
/// the path this type optimizes for.
enum GlassesPresentationLayer {
    /// `[]` for a turn with no translation (Ukrainian speech, or a turn
    /// whose translation is empty/whitespace-only) — no translation page
    /// and no reply pages either, since replies only ever exist
    /// alongside a genuinely translated foreign-language turn.
    static func pages(
        for turn: ConversationTurn,
        maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage
    ) -> [String] {
        guard let translation = turn.ukrainianTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translation.isEmpty
        else {
            return []
        }

        var pages = GlassesTextPaginator.pages(for: translation, maxCharactersPerPage: maxCharactersPerPage)
        pages.append(contentsOf: replyPages(for: turn.suggestedReplies, maxCharactersPerPage: maxCharactersPerPage))
        return pages
    }

    /// Packs each reply + its Ukrainian meaning as one indivisible block,
    /// sorted by `ordering` (not array position — see
    /// `SuggestedReply.ordering`'s own doc comment) and capped at 3,
    /// matching the product's G2 display limit regardless of how many a
    /// generator actually returned. A reply whose own text is empty/
    /// whitespace-only is dropped before numbering, so the remaining
    /// replies are numbered contiguously (never "1., 3." with a gap).
    private static func replyPages(for replies: [SuggestedReply], maxCharactersPerPage: Int) -> [String] {
        let validReplies = replies
            .sorted { $0.ordering < $1.ordering }
            .prefix(3)
            .filter { !$0.originalLanguageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let blocks = validReplies.enumerated().map { index, reply in
            "\(index + 1). \(reply.originalLanguageText)\n\(reply.ukrainianText)"
        }

        var pages: [String] = []
        var currentBlocks: [String] = []
        var currentLength = 0

        for block in blocks {
            let separatorLength = currentBlocks.isEmpty ? 0 : 2 // "\n\n" between blocks sharing a page
            let addedLength = block.count + separatorLength

            if !currentBlocks.isEmpty, currentLength + addedLength > maxCharactersPerPage {
                pages.append(currentBlocks.joined(separator: "\n\n"))
                currentBlocks = []
                currentLength = 0
            }

            if block.count > maxCharactersPerPage {
                // A single reply pair too long to fit on any page alone —
                // rare (replies are meant to be short), handled rather
                // than silently overflowing: split via the same
                // paginator used for translations, in isolation so
                // nothing else shares in its overflow.
                if !currentBlocks.isEmpty {
                    pages.append(currentBlocks.joined(separator: "\n\n"))
                    currentBlocks = []
                    currentLength = 0
                }
                pages.append(contentsOf: GlassesTextPaginator.pages(for: block, maxCharactersPerPage: maxCharactersPerPage))
                continue
            }

            currentBlocks.append(block)
            currentLength += addedLength
        }

        if !currentBlocks.isEmpty {
            pages.append(currentBlocks.joined(separator: "\n\n"))
        }

        return pages
    }
}
