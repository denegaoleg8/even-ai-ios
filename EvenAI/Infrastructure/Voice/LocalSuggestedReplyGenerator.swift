import Foundation
import FoundationModels

/// AI Conversation's reply-provider stack, entirely local/optional —
/// `LocalSuggestedReplyGenerator` is the type `EvenAIApp` actually wires
/// as the production `SuggestedReplyGenerating`. Tries, in order:
///
/// 1. **Apple `FoundationModels`** (`FoundationModelsReplyGenerator`), if
///    truly available right now (iOS 26+, device eligible, Apple
///    Intelligence ON, model assets ready — checked explicitly before
///    ever constructing a session).
/// 2. **`LightweightLocalReplyGenerator`** — a rule-based engine needing
///    NOTHING beyond what's already on the phone. This is the tier that
///    actually matters on real hardware today: physical testing confirmed
///    `SystemLanguageModel` reports `.unavailable(.appleIntelligenceNotEnabled)`
///    on the test device, which used to mean "no replies, ever" —
///    `LightweightLocalReplyGenerator` never depends on Apple
///    Intelligence at all, so it always works.
/// 3. **No replies** — if a caller ever passes a `SuggestedReplyGenerating`
///    that isn't this stack (e.g. an explicit, opt-in cloud provider, not
///    currently wired by default anywhere), that's this type's own
///    business, not this stack's; this stack itself has no cloud tier —
///    Railway being unavailable must never mean "no suggested replies
///    ever again," and it must also never mean silently reaching for
///    Railway automatically as a fallback (that would reintroduce
///    exactly the backend dependency the local-first pass exists to
///    remove). If BOTH local tiers somehow throw (in practice, only tier
///    1 ever does — tier 2 has no failure mode beyond an empty/whitespace
///    utterance, which legitimately means "nothing to reply to"), this
///    throws the tier-2 error, honestly — `AIConversationEngine
///    .generateSuggestedReplies` already treats any thrown error as "no
///    replies this turn," never a session failure.
///
/// Deployment-target compatible (this app's own deployment target is iOS
/// 18.0; `FoundationModels` requires iOS 26.0+), mirroring
/// `TranscriptionProviderRouter`'s own shape: a router usable at the
/// app's real deployment target, with the real `@available`-gated tier
/// reached only through an `#available` check.
struct LocalSuggestedReplyGenerator: SuggestedReplyGenerating {
    private let lightweight: LightweightLocalReplyGenerator
    /// Testability seam ONLY — production (the default, `nil`) always
    /// uses the real `#available`-gated `FoundationModelsReplyGenerator`.
    /// Tests that need to prove "FoundationModels unavailable/failing →
    /// lightweight fallback engages" deterministically (without depending
    /// on the real device/simulator's actual Apple Intelligence state)
    /// inject a fake tier-1 provider here instead — everything else about
    /// this type's behavior (still tries tier 1 first, still falls back
    /// to `lightweight` on any thrown error) is identical either way.
    private let foundationModelsOverride: (any SuggestedReplyGenerating)?

    init(
        lightweight: LightweightLocalReplyGenerator = LightweightLocalReplyGenerator(),
        foundationModelsOverride: (any SuggestedReplyGenerating)? = nil
    ) {
        self.lightweight = lightweight
        self.foundationModelsOverride = foundationModelsOverride
    }

    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        if let foundationModelsOverride {
            do {
                return try await foundationModelsOverride.generateReplies(for: turn, context: context)
            } catch {
                DiagnosticTrace.log("REPLIES_FOUNDATION_MODELS_FALLBACK", "reason=\(error)")
                return try await lightweight.generateReplies(for: turn, context: context)
            }
        }
        if #available(iOS 26.0, *) {
            do {
                return try await FoundationModelsReplyGenerator.shared.generateReplies(for: turn, context: context)
            } catch {
                DiagnosticTrace.log("REPLIES_FOUNDATION_MODELS_FALLBACK", "reason=\(error)")
                return try await lightweight.generateReplies(for: turn, context: context)
            }
        }
        DiagnosticTrace.log("REPLIES_FOUNDATION_MODELS_FALLBACK", "reason=osVersionTooOld")
        return try await lightweight.generateReplies(for: turn, context: context)
    }
}

/// Structured output schema for the model — `@Generable`/`@Guide` (both
/// from `FoundationModels`) let `LanguageModelSession.respond(to:generating:)`
/// return this shape directly, guided/validated by the framework itself,
/// rather than this app having to parse free-form text out of a raw
/// string response (which is what `NetworkSuggestedReplyGenerator`'s
/// backend counterpart does server-side via its own prompt engineering —
/// on-device, `FoundationModels` does the equivalent structurally).
@available(iOS 26.0, *)
@Generable
struct ReplySuggestionSet {
    @Guide(description: "Between 2 and 3 short, natural, DISTINCT replies that directly answer or respond to the given phrase — never generic filler unrelated to what was actually said")
    var replies: [ReplySuggestionItem]
}

@available(iOS 26.0, *)
@Generable
struct ReplySuggestionItem {
    @Guide(description: "The reply itself, written in the SAME language as the original phrase")
    var sourceLanguageText: String
    @Guide(description: "The Ukrainian translation of that exact reply")
    var ukrainianText: String
}

/// The real on-device implementation — Apple's `FoundationModels`
/// framework, `SystemLanguageModel`/`LanguageModelSession`. A fresh
/// `LanguageModelSession` per call (not a single shared, persistent
/// session): each Live Translation turn's reply generation is already an
/// independent, stateless request (matching `NetworkSuggestedReplyGenerator`'s
/// own per-call shape and `SuggestedReplyContext`'s own "bounded recent
/// history passed explicitly each time" design) — a fresh session avoids
/// any need to reason about concurrent/overlapping turns sharing one
/// session's internal state, the same class of problem
/// `AppleLanguageTranslator`'s own doc comment describes having to solve
/// for a session it genuinely had to share (its own `TranslationSession`,
/// which SwiftUI only vends one of); `LanguageModelSession` has no such
/// constraint, so there's no reason to take on that complexity here.
@available(iOS 26.0, *)
struct FoundationModelsReplyGenerator: SuggestedReplyGenerating {
    static let shared = FoundationModelsReplyGenerator()

    /// How much recent conversation context to include in the prompt —
    /// mirrors `SuggestedReplyContext`'s own already-bounded `recentTurns`
    /// (itself capped to 6 by `AIConversationEngine.generateSuggestedReplies`),
    /// trimmed further here to keep the on-device prompt small and fast;
    /// reply relevance depends overwhelmingly on the LATEST phrase, not a
    /// long history.
    private static let maxRecentTurnsInPrompt = 4

    private static let instructions = """
        You are helping someone in a live, spoken conversation reply quickly. \
        Given the other person's most recent phrase (and recent conversation \
        context, if any), suggest 2 to 3 short, natural replies a person \
        might actually say next. Each reply must be written in the SAME \
        language as the original phrase, and must directly answer or \
        respond to what was actually said — never a generic greeting or \
        filler unrelated to the content. Keep every reply short enough to \
        read at a glance on a small display.
        """

    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw LocalReplyUnavailableError(reason: .deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            throw LocalReplyUnavailableError(reason: .appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            throw LocalReplyUnavailableError(reason: .modelNotReady)
        case .unavailable:
            // `UnavailableReason` isn't guaranteed exhaustive-switchable
            // across OS versions (Apple may add cases) — any reason not
            // explicitly named above still means "not available right
            // now," classified as the closest honest existing case
            // rather than crashing on a future unknown one.
            throw LocalReplyUnavailableError(reason: .modelNotReady)
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = Self.prompt(for: turn, context: context)
        let response = try await session.respond(to: prompt, generating: ReplySuggestionSet.self)
        return response.content.replies.enumerated().map { index, item in
            SuggestedReply(
                originalLanguageText: item.sourceLanguageText,
                ukrainianText: item.ukrainianText,
                ordering: index
            )
        }
    }

    private static func prompt(for turn: ConversationTurn, context: SuggestedReplyContext) -> String {
        var lines: [String] = []
        // Phase 3: optional Personal AI enrichment. Already priority-ordered
        // and token-budgeted upstream; absent (nil) in every fallback case, so
        // this block is a pure no-op whenever enrichment did not apply.
        if let personal = context.personalAIContext, !personal.isEmpty {
            lines.append(personal)
            lines.append("")
        }
        let recent = context.recentTurns.suffix(maxRecentTurnsInPrompt)
        if !recent.isEmpty {
            lines.append("Recent conversation, oldest first:")
            for recentTurn in recent {
                lines.append("- \(recentTurn.originalText)")
            }
        }
        lines.append("Latest phrase to reply to: \"\(turn.originalText)\"")
        return lines.joined(separator: "\n")
    }
}
