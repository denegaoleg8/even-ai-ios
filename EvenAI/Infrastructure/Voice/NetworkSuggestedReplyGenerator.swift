import Foundation

/// Milestone 7: real, backend-calling implementation of
/// `SuggestedReplyGenerating` — see that protocol's doc comment ("a future
/// concrete implementation... is whatever actually calls out to a chosen
/// provider") and `NoOpSuggestedReplyGenerator`'s ("Replacing this with a
/// real, backend-calling implementation is exactly the next milestone's
/// job"). Talks to the Even AI backend's `POST /suggested-replies`
/// endpoint via the shared `AuthenticatedAPIClient` — same pattern as
/// `NetworkChatService`: no direct `URLSession` use here, and no AI
/// provider API key anywhere in this app (the backend is the only thing
/// that ever holds it — this file doesn't even name which provider it is,
/// keeping the "provider-agnostic" promise `SuggestedReplyGenerating`
/// makes).
///
/// Every failure mode (offline, HTTP error, malformed response body) is a
/// plain `throw` — nothing here ever produces a partial or best-guess
/// result. `AIConversationEngine.generateSuggestedReplies(for:)` is the
/// one place that decides what a thrown error means for the live
/// session (leave `suggestedReplies` empty, keep the translation turn
/// exactly as already displayed), so this type doesn't need its own
/// fallback logic to satisfy "never crash the live session."
struct NetworkSuggestedReplyGenerator: SuggestedReplyGenerating {
    private let apiClient: AuthenticatedAPIClient
    /// Bounds how much conversation history/context is sent per request,
    /// regardless of how long a live session has run or how much
    /// background material the user has added — keeps request size and
    /// prompt-token usage bounded. Mirrors `SuggestedReplyContext`'s own
    /// oldest-first convention: `.suffix(_:)` keeps the most *recent*
    /// entries, which are what's actually relevant to the current turn.
    private static let maxRecentTurnsSent = 10
    private static let maxContextItemsSent = 20

    init(apiClient: AuthenticatedAPIClient) {
        self.apiClient = apiClient
    }

    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        let requestBody = SuggestedRepliesRequestDTO(
            turn: .init(turn),
            recentTurns: context.recentTurns.suffix(Self.maxRecentTurnsSent).map(SuggestedRepliesRequestDTO.TurnDTO.init),
            contextItems: context.contextItems.suffix(Self.maxContextItemsSent).map(SuggestedRepliesRequestDTO.ContextItemDTO.init)
        )
        let data = try await apiClient.post("suggested-replies", body: try JSONEncoder.evenAI.encode(requestBody))
        let decoded = try JSONDecoder.evenAI.decode(SuggestedRepliesResponseDTO.self, from: data)
        return decoded.replies.enumerated().map { index, reply in
            SuggestedReply(
                originalLanguageText: reply.originalLanguageText,
                ukrainianText: reply.ukrainianText,
                ordering: reply.ordering ?? index
            )
        }
    }
}

// MARK: - Wire format

/// File-private DTOs — never exposed beyond this file, matching
/// `ChatAPIDTOs.swift`'s existing convention of keeping wire shape and
/// domain models separate.
private struct SuggestedRepliesRequestDTO: Encodable {
    struct TurnDTO: Encodable {
        var originalText: String
        var detectedLanguage: String?
        var ukrainianTranslation: String?

        init(_ turn: ConversationTurn) {
            originalText = turn.originalText
            detectedLanguage = turn.detectedLanguage
            ukrainianTranslation = turn.ukrainianTranslation
        }
    }

    struct ContextItemDTO: Encodable {
        var kind: String
        var text: String

        init(_ item: ContextItem) {
            kind = item.kind.rawValue
            text = item.text
        }
    }

    var turn: TurnDTO
    /// Oldest-first, matching `SuggestedReplyContext.recentTurns`'
    /// documented convention — the backend's prompt builder relies on
    /// this order to present history chronologically.
    var recentTurns: [TurnDTO]
    var contextItems: [ContextItemDTO]
}

private struct SuggestedRepliesResponseDTO: Decodable {
    struct ReplyDTO: Decodable {
        var originalLanguageText: String
        var ukrainianText: String
        /// Optional on the wire — defensively defaulted to array position
        /// below if the backend ever omits it, rather than failing the
        /// whole decode over one missing field.
        var ordering: Int?
    }

    var replies: [ReplyDTO]
}
