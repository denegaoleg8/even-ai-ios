import Foundation

/// Vendor-specific wire shapes for the OpenAI **Responses API**
/// (`POST /v1/responses`), confined entirely to this `Infrastructure/…/OpenAI`
/// boundary. Nothing here is imported by `Core/Domain` or by
/// `RemotePersonalAIModelProvider` — they only ever see the provider-neutral
/// `PersonalAIRemoteRequest`/`PersonalAIRemoteResponse`.
///
/// Built conceptually against the Responses API's documented shape — this
/// has never been exercised against the real endpoint from this codebase
/// (no network access here), so **verify against the live API docs before
/// enabling any real traffic**. Decoding is deliberately defensive (see
/// `OpenAIResponsesMapper`): every field is optional, unrecognized output
/// item/content types are ignored rather than causing a decode failure,
/// and a genuinely malformed body still fails safely.
/// `Decodable` too — only so tests can round-trip a captured request body
/// back into a DTO to assert on it (see `OpenAIRemoteEndToEndTests`); the
/// production adapter only ever encodes this, never decodes it.
struct OpenAIResponsesRequestDTO: Codable, Sendable, Equatable {
    var model: String
    /// Maps from `PersonalAIRemoteRequest.contextText` — the system/
    /// developer-level instructions for this turn.
    var instructions: String?
    var input: [OpenAIResponsesInputItem]
    var max_output_tokens: Int?
}

struct OpenAIResponsesInputItem: Codable, Sendable, Equatable {
    /// `"user"` or `"assistant"` — never anything else from this adapter.
    var role: String
    var content: String
}

/// Top-level Responses API response. Every field optional: a response
/// missing a field this adapter doesn't understand must not crash decoding
/// — `OpenAIResponsesMapper` decides what "missing" means.
struct OpenAIResponsesResponseDTO: Decodable, Sendable {
    var id: String?
    var status: String?
    var output: [OpenAIResponsesOutputItem]?
    var error: OpenAIResponsesErrorDTO?
}

struct OpenAIResponsesOutputItem: Decodable, Sendable {
    /// Only `"message"` is understood by this adapter today. A future
    /// item type (e.g. a tool call, reasoning trace) decodes fine — its
    /// `type` just won't match `"message"` and the mapper skips it,
    /// per "ignore unsupported future output items safely."
    var type: String?
    var role: String?
    var content: [OpenAIResponsesContentPart]?
}

struct OpenAIResponsesContentPart: Decodable, Sendable {
    /// Only `"output_text"` is understood by this adapter today. Same
    /// forward-compatibility reasoning as `OpenAIResponsesOutputItem.type`.
    var type: String?
    var text: String?
}

struct OpenAIResponsesErrorDTO: Decodable, Sendable {
    var message: String?
    var type: String?
    var code: String?
}
