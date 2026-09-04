import Foundation

/// Pure mapping between the provider-neutral remote seam
/// (`PersonalAIRemoteRequest`/`PersonalAIRemoteResponse`) and the OpenAI
/// Responses API wire shapes. No I/O, no networking — `OpenAIResponsesTransport`
/// is the only caller.
enum OpenAIResponsesMapper {

    /// `remote.contextText` becomes `instructions` (empty → `nil`, never an
    /// empty string sent as if it were real content); `remote.recentMessages`
    /// map straight across in order; `remote.userMessage` is appended last
    /// as the newest `"user"` turn. Nothing beyond what `RemotePersonalAIModelProvider.remoteRequest(from:)`
    /// already put into `remote` reaches this DTO — no raw memory, no store
    /// reference, because `PersonalAIRemoteRequest` has no field for them.
    static func request(from remote: PersonalAIRemoteRequest, model: String) -> OpenAIResponsesRequestDTO {
        var input = remote.recentMessages.map {
            OpenAIResponsesInputItem(role: $0.role.rawValue, content: $0.text)
        }
        input.append(OpenAIResponsesInputItem(role: "user", content: remote.userMessage))
        return OpenAIResponsesRequestDTO(
            model: model,
            instructions: remote.contextText.isEmpty ? nil : remote.contextText,
            input: input,
            max_output_tokens: remote.maxOutputTokens
        )
    }

    /// Robust, defensive parsing (§6):
    /// - an explicit `error` object → `.hardFailure`, using OpenAI's own
    ///   message when present;
    /// - `output` missing, empty, or containing no recognized text →
    ///   `.hardFailure("empty output")` — **never fabricates text**;
    /// - only `type == "message"` items and `type == "output_text"` content
    ///   parts are read; any other type (a future tool call, reasoning
    ///   trace, etc.) is silently skipped, not treated as an error;
    /// - multiple text parts are concatenated in order, matching how a
    ///   single message can carry several output_text chunks.
    static func response(from dto: OpenAIResponsesResponseDTO) throws -> PersonalAIRemoteResponse {
        if let error = dto.error {
            throw PersonalAIProviderOutcome.hardFailure(reason: error.message ?? error.type ?? "OpenAI returned an error")
        }
        let messageItems = (dto.output ?? []).filter { $0.type == "message" }
        let contentParts: [OpenAIResponsesContentPart] = messageItems.flatMap { $0.content ?? [] }
        let textParts: [String] = contentParts
            .filter { $0.type == "output_text" }
            .compactMap { $0.text }
        let text = textParts.joined()
        guard !text.isEmpty else {
            throw PersonalAIProviderOutcome.hardFailure(reason: "empty output")
        }
        return PersonalAIRemoteResponse(text: text)
    }
}
