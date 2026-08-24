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
/// ## The "translation disappears when replies arrive" bug this fixes
///
/// The previous design produced TWO DIFFERENT page sets for one turn: a
/// translation-only set for the first display call, and a completely
/// separate `replyLeadingPages(for:)` set (replies first, translation
/// pages after) for the automatic "replies just finished" update. Because
/// `MentraGlassesTransport.displayPages(_:)` always resets to page 1 of
/// whatever set it's given, going from "page 1 = translation" to "page 1 =
/// reply 1" meant the translation the user was just reading visibly
/// vanished, replaced by reply content — exactly the physical symptom
/// reported ("translated text appears first, then it disappears,
/// suggested replies replace it").
///
/// The fix: there is now only ONE page format per turn, produced by this
/// one function, used for BOTH the initial translation-only display call
/// and the later "replies arrived" update call. Every page carries the
/// SAME header — the original spoken phrase and its Ukrainian translation
/// — with a reply (if any) shown below it. Before any replies exist, the
/// header is the only page. Once replies arrive, calling this function
/// again for the same turn produces one page per reply, each still
/// carrying the identical header — so redisplaying never removes the
/// translation, it only adds a reply section beneath it. Swiping (see
/// `MentraGlassesTransport`'s touch-event handling, unchanged) still just
/// moves through whatever page set is currently active — which now means
/// "moves between replies," never "moves away from the translation,"
/// since the translation is baked into every page.
enum GlassesPresentationLayer {
    /// `[]` for a turn with no translation (Ukrainian speech, or a turn
    /// whose translation is empty/whitespace-only) — no page at all,
    /// matching the product rule that G2 only ever shows a genuinely
    /// translated foreign-language turn.
    ///
    /// With no replies yet (or once generation finishes with nothing
    /// usable), the result is the single-page (or, for a very long
    /// phrase/translation, multi-page) header alone — "Source +
    /// translation, no reply section yet" is an explicitly allowed
    /// display state (see this type's doc comment and
    /// `LiveTranslationService`'s turn/display state model), not a
    /// placeholder needing special-casing here.
    ///
    /// With replies present, the result is one page PER reply (capped at
    /// 3, sorted by `ordering`, empty-text replies dropped and the rest
    /// renumbered contiguously) — never multiple replies packed onto one
    /// page — because the product requirement is "swiping moves to the
    /// next reply," which only holds if each reply is its own page. Each
    /// such page repeats the full header, so the header is never the
    /// thing a swipe navigates away from.
    static func pages(
        for turn: ConversationTurn,
        maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage
    ) -> [String] {
        guard let translation = turn.ukrainianTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translation.isEmpty
        else {
            return []
        }

        let header = conversationHeader(originalText: turn.originalText, translation: translation)
        let validReplies = turn.suggestedReplies
            .sorted { $0.ordering < $1.ordering }
            .prefix(3)
            .filter { !$0.originalLanguageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !validReplies.isEmpty else {
            return GlassesTextPaginator.pages(for: header, maxCharactersPerPage: maxCharactersPerPage)
        }

        return validReplies.enumerated().flatMap { index, reply -> [String] in
            let replyBlock = "Reply \(index + 1):\n\(reply.originalLanguageText)\nUA: \(reply.ukrainianText)"
            let combined = header + "\n\n" + replyBlock
            guard combined.count > maxCharactersPerPage else { return [combined] }
            // Rare overflow (a reply too long, alongside the header, to
            // fit in one page) — degrade to GlassesTextPaginator's normal
            // multi-page split rather than silently truncating. No
            // overlap-word repetition here (that feature is meant for
            // continuous prose being read top-to-bottom, not a
            // header+reply block); the header only survives onto the
            // first of these overflow pages, which is an accepted, rare
            // degradation, not a regression from the previous behavior.
            return GlassesTextPaginator.pages(for: combined, maxCharactersPerPage: maxCharactersPerPage, overlapWordCount: 0)
        }
    }

    /// A single, unpaginated page for a still-in-progress (partial) or
    /// just-finalized utterance being streamed to G2 in place — major
    /// performance pass ("translation should begin appearing as close to
    /// real time as technically possible"). Deliberately NOT run through
    /// `GlassesTextPaginator`/multi-page splitting: a streaming update
    /// has no reply section to swipe to yet, so there is nothing for
    /// pagination to serve, and a growing partial changing every ~150ms
    /// isn't a stable enough target for a swipeable multi-page layout
    /// anyway — this always sends exactly one page.
    ///
    /// `translation == nil` (no language known yet for this utterance, or
    /// the debounced translate call hasn't resolved yet) renders `source`
    /// alone — the same "Source, no translation section yet" allowance
    /// `pages(for:)` already makes for "no replies yet," extended one
    /// level earlier in the turn's lifecycle.
    static func streamingPage(source: String, translation: String?) -> String {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty else {
            return trimmedSource
        }
        return conversationHeader(originalText: trimmedSource, translation: translation)
    }

    /// The persistent header shown on every page for a turn: the original
    /// spoken phrase, then its Ukrainian translation — see this type's
    /// doc comment for why this is now baked into every page rather than
    /// living on a page of its own.
    private static func conversationHeader(originalText: String, translation: String) -> String {
        "\(originalText)\n\nUA: \(translation)"
    }
}
