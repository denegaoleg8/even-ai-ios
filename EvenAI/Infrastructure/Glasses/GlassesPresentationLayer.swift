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

    /// The G2 conversation timeline (major redesign pass, Conversation
    /// Mode) — `pages(for:)`'s output (current turn + its replies, page
    /// 0 always "live"), with ONE bounded page of look-back context
    /// appended at the very end if `previousTurn` has a translation.
    /// Deliberately just one prior turn, not an arbitrary-depth scroll:
    /// G2 is a fixed 576×288 canvas with no native scroll surface — the
    /// product's own instruction is "render a WINDOW of it," not attempt
    /// infinite history on-device. Appended AFTER replies (not before),
    /// so "page 0 = live" stays a simple, unconditional invariant
    /// `LiveTranslationService`'s follow-live tracking depends on
    /// (`GlassesNavigationEvent.pageChanged(index: 0)` always means "back
    /// on the live turn," regardless of how many reply pages exist for
    /// it) — swiping past all replies is what reaches history context,
    /// mirroring Even's own "Teleprompt" reference UX (auto-forward
    /// content, manual swipe for anything else).
    static func conversationPages(
        for currentTurn: ConversationTurn,
        previousTurn: ConversationTurn?,
        maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage
    ) -> [String] {
        var result = pages(for: currentTurn, maxCharactersPerPage: maxCharactersPerPage)
        guard !result.isEmpty else { return result } // no translation yet — no page at all, same as pages(for:)
        if let previousTurn, let contextPage = historyViewportPage(for: previousTurn, maxCharactersPerPage: maxCharactersPerPage) {
            result.append(contextPage)
        }
        return result
    }

    /// Meeting Mode's variant of `pages(for:)` — restores "replies must
    /// ALSO exist" for Meeting Mode without violating its own priority
    /// order ("live speech > translation/history > replies"): unlike
    /// `pages(for:)`, where a reply is merged directly onto page 0 (so it
    /// becomes what's immediately, automatically shown), here page 0 is
    /// ALWAYS the plain header alone — identical to what was already on
    /// screen before replies existed — with reply pages appended
    /// AFTERWARD as additional, swipeable content. Since
    /// `GlassesTransport.displayPages(_:)` resets to page 0 of whatever
    /// set it's given, redisplaying this set never changes what's
    /// actively shown; it only makes the replies newly REACHABLE by
    /// swiping past the header, exactly the "show compact suggested
    /// replies without replacing conversation history" requirement.
    /// `[]` under the same "no translation yet" condition as `pages(for:)`.
    static func meetingPages(
        for turn: ConversationTurn,
        maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage
    ) -> [String] {
        guard let translation = turn.ukrainianTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translation.isEmpty
        else {
            return []
        }
        let header = conversationHeader(originalText: turn.originalText, translation: translation)
        let headerPages = GlassesTextPaginator.pages(for: header, maxCharactersPerPage: maxCharactersPerPage)
        let validReplies = validSortedReplies(for: turn)
        guard !validReplies.isEmpty else { return headerPages }
        let replyPages = self.replyPages(header: header, validReplies: validReplies, maxCharactersPerPage: maxCharactersPerPage)
        return headerPages + replyPages
    }

    /// Meeting Mode's counterpart to `conversationPages(for:previousTurn:)`
    /// — `meetingPages(for:)`'s output (header page(s) first, unchanged by
    /// replies existing; then reply pages, if any) with the same one
    /// bounded page of look-back context appended at the end.
    static func meetingConversationPages(
        for currentTurn: ConversationTurn,
        previousTurn: ConversationTurn?,
        maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage
    ) -> [String] {
        var result = meetingPages(for: currentTurn, maxCharactersPerPage: maxCharactersPerPage)
        guard !result.isEmpty else { return result }
        if let previousTurn, let contextPage = historyViewportPage(for: previousTurn, maxCharactersPerPage: maxCharactersPerPage) {
            result.append(contextPage)
        }
        return result
    }

    /// Shared by both `pages(for:)` and `meetingPages(for:)`: at most 3
    /// replies, sorted by `ordering`, with empty-text ones dropped —
    /// see `pages(for:)`'s own doc comment for why this exact rule.
    private static func validSortedReplies(for turn: ConversationTurn) -> [SuggestedReply] {
        Array(
            turn.suggestedReplies
                .sorted { $0.ordering < $1.ordering }
                .prefix(3)
                .filter { !$0.originalLanguageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    /// Shared by both `pages(for:)` and `meetingPages(for:)`: one page per
    /// reply, each still carrying the full header (see `pages(for:)`'s own
    /// doc comment on why every page repeats it).
    private static func replyPages(header: String, validReplies: [SuggestedReply], maxCharactersPerPage: Int) -> [String] {
        validReplies.enumerated().flatMap { index, reply -> [String] in
            let replyBlock = "Reply \(index + 1):\n\(reply.originalLanguageText)\nUA: \(reply.ukrainianText)"
            let combined = header + "\n\n" + replyBlock
            guard combined.count > maxCharactersPerPage else { return [combined] }
            return GlassesTextPaginator.pages(for: combined, maxCharactersPerPage: maxCharactersPerPage, overlapWordCount: 0)
        }
    }

    /// A single dedicated page for one turn's history-viewport content —
    /// used both by `conversationPages(for:previousTurn:)` (to append the
    /// live turn's trailing look-back page) AND, on demand, directly by
    /// `LiveTranslationService.renderHistoryViewport(anchorTurnID:)` when
    /// `.browsingHistory` is entered/re-entered — so history always
    /// renders identically regardless of which of those two call sites
    /// produced it. `nil` if `turn` has no usable translation (Ukrainian
    /// speech, a failed/removed turn — shouldn't happen since only
    /// committed, translated turns ever reach `agentContextStore`, but
    /// defensive regardless).
    static func historyViewportPage(for turn: ConversationTurn, maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage) -> String? {
        guard let translation = turn.ukrainianTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translation.isEmpty
        else {
            return nil
        }
        let page = "Previous:\n" + conversationHeader(originalText: turn.originalText, translation: translation)
        guard page.count > maxCharactersPerPage else { return page }
        // Rare overflow — degrade to a hard truncation rather than
        // multi-page-splitting a page whose whole point is being ONE
        // compact look-back summary; unlike the live turn's own header,
        // this isn't the primary content, so losing its tail to fit one
        // page is an acceptable, rare degradation.
        return String(page.prefix(maxCharactersPerPage))
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
