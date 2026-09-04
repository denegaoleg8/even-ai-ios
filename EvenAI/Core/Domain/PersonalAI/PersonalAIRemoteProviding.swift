import Foundation

/// One turn of bounded conversation history handed to a remote transport —
/// deliberately narrower than `PersonalAIChatMessage` (no id, timestamp,
/// sync/tombstone fields, `eligibleForMemory` flag): a remote vendor gets
/// only what it needs to generate a reply, nothing about how this app
/// stores, syncs, or archives the conversation.
struct PersonalAIRemoteMessage: Sendable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    var role: Role
    var text: String
}

/// The minimal, provider-neutral shape of what a remote tier is allowed to
/// receive. Built once, by `RemotePersonalAIModelProvider.remoteRequest(from:)`,
/// from a `PersonalAIGenerationRequest` — never the full Domain request
/// itself, and never a raw `[MemoryRecord]`, `Rule`, or store reference.
///
/// `contextText` is exactly the same already-rendered, already-budgeted
/// block Apple Foundation Models receives as
/// `personalContext.systemPromptText` — whatever `PersonalAIContextBuilder`
/// already decided was relevant, already assembled into text. This type
/// structurally cannot carry `personalContext.relevantMemories`,
/// `relevantProjects`, `relevantPeople`, or `historicalExcerpts` (the raw,
/// structured records) — it has no field for them, and no conformer of
/// `PersonalAIRemoteTransport` ever sees the store.
struct PersonalAIRemoteRequest: Sendable, Equatable {
    var contextText: String
    var recentMessages: [PersonalAIRemoteMessage]
    var userMessage: String
    var maxOutputTokens: Int
}

struct PersonalAIRemoteResponse: Sendable, Equatable {
    var text: String
}

/// Narrow, vendor-neutral transport for a remote Personal AI generation
/// call. A future OpenAI/Anthropic/Gemini/self-hosted adapter is just
/// another conformer in `Infrastructure/` — this protocol, and everything
/// that depends on it (`RemotePersonalAIModelProvider`, the router), never
/// imports a vendor SDK or references a vendor request/response shape.
/// No CloudKit, R2, or Apple Foundation Models type appears anywhere near
/// this seam.
protocol PersonalAIRemoteTransport: Sendable {
    /// `authorization` is an opaque bearer value supplied by whatever
    /// composed this transport (see `PersonalAIRemoteAuthorizing`) — this
    /// protocol never reads, parses, or validates it, only forwards it to
    /// whatever concrete vendor call a real conformer makes.
    func generate(_ request: PersonalAIRemoteRequest, authorization: String) async throws -> PersonalAIRemoteResponse
}

/// Credential boundary for a remote transport. No conformer in this
/// codebase reads a real secret yet — this exists so a future one (a
/// Keychain-backed token, a backend-issued short-lived credential, etc.)
/// can supply a live value without `RemotePersonalAIModelProvider` or the
/// router ever knowing what kind of credential it is, or embedding one.
protocol PersonalAIRemoteAuthorizing: Sendable {
    /// `nil` ⇒ no credential is currently available — the caller must
    /// fail as `.unavailable`, never attempt an unauthenticated request.
    func currentToken() async -> String?
}
