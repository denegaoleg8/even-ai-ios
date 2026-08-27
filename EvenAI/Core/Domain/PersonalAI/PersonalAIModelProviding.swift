import Foundation

/// Provider-agnostic abstraction over generating a Personal AI response.
/// **No AI vendor is named here or anywhere in `Core`** — exactly the
/// discipline `SuggestedReplyGenerating` already follows. The user's memory
/// must be portable independently of whichever model answers, so the model
/// is a swappable dependency behind this one method.
///
/// Phase 1 ships `OnDevicePersonalAIModelProvider` (Apple `FoundationModels`
/// when available, a deterministic context-aware fallback otherwise). A
/// future self-hosted or API-backed provider is just another conformer.
protocol PersonalAIModelProviding: Sendable {
    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult
}

struct PersonalAIGenerationRequest: Hashable, Sendable {
    /// The compact personalization block from `PersonalAIContextBuilding`.
    var personalContext: PersonalAIContext
    /// Conversation so far, oldest-first.
    var messages: [PersonalAIChatMessage]
    /// The new user message to respond to.
    var userMessage: String
    var maxOutputTokens: Int

    init(
        personalContext: PersonalAIContext,
        messages: [PersonalAIChatMessage],
        userMessage: String,
        maxOutputTokens: Int = 500
    ) {
        self.personalContext = personalContext
        self.messages = messages
        self.userMessage = userMessage
        self.maxOutputTokens = maxOutputTokens
    }
}

struct PersonalAIGenerationResult: Hashable, Sendable {
    var text: String
    /// Which tier actually answered — surfaced in the UI as a small note,
    /// never as an error.
    var provider: Provider
    /// True if the provider consciously used retrieved memory/rules to
    /// shape the answer (tests assert this when context was available).
    var usedPersonalization: Bool

    enum Provider: String, Hashable, Sendable {
        case onDeviceFoundationModel
        case heuristic
        case cloud
        case fake
    }
}

/// One message in a Personal AI conversation. Separate from Chat's `Message`
/// (which carries `chatID`, `status`, streaming state) — this is the minimal
/// shape the model provider and archive need.
struct PersonalAIChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable { case user, assistant, system }

    let id: UUID
    var role: Role
    var text: String
    var timestamp: Date
    /// Set false for a message the user marked (or whose conversation was
    /// marked) "do not remember" — the extractor skips it.
    var eligibleForMemory: Bool

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .now, eligibleForMemory: Bool = true) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.eligibleForMemory = eligibleForMemory
    }
}

enum PersonalAIError: Error, Equatable, Sendable {
    case modelUnavailable(reason: String)
    case generationFailed(String)
    case cancelled
    case rejectedContent(reason: String)

    var userFacingMessage: String {
        switch self {
        case .modelUnavailable(let reason):
            return "Personal AI model isn't available right now (\(reason)). Your memory is still being recorded."
        case .generationFailed:
            return "Personal AI couldn't complete that response. Try again."
        case .cancelled:
            return "Cancelled."
        case .rejectedContent(let reason):
            return "That wasn't stored: \(reason)."
        }
    }
}
