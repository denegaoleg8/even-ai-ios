import Foundation
import FoundationModels

/// Local-first architecture pass, restoring suggested replies: the
/// production `SuggestedReplyGenerating` implementation now prefers
/// Apple's on-device `FoundationModels` framework over any backend call —
/// Railway being unavailable must never mean "no suggested replies ever
/// again," and it must also never mean silently reaching for Railway
/// automatically as a fallback (that would reintroduce exactly the
/// backend dependency the local-first pass exists to remove).
///
/// `LocalSuggestedReplyGenerator` is the type `EvenAIApp` actually wires
/// in — deployment-target compatible (this app's own deployment target is
/// iOS 18.0; `FoundationModels` requires iOS 26.0+), mirroring
/// `TranscriptionProviderRouter`'s own shape: a router usable at the
/// app's real deployment target, with the real `@available`-gated
/// implementation reached only through an `#available` check. On iOS
/// 26.0+, delegates to `FoundationModelsReplyGenerator`; below that, or
/// whenever the on-device model itself isn't usable (device ineligible,
/// Apple Intelligence disabled, model assets not ready — checked
/// EXPLICITLY, before ever constructing a session), throws
/// `LocalReplyUnavailableError` — never a network call, never a fallback
/// to any backend.
struct LocalSuggestedReplyGenerator: SuggestedReplyGenerating {
    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        if #available(iOS 26.0, *) {
            return try await FoundationModelsReplyGenerator.shared.generateReplies(for: turn, context: context)
        }
        throw LocalReplyUnavailableError(reason: .osVersionTooOld)
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
    /// (itself capped to 6 by `LiveTranslationService.generateSuggestedReplies`),
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
