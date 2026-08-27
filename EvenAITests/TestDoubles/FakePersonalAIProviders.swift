import Foundation
@testable import EvenAI

/// A `PersonalAIModelProviding` that echoes a scripted reply and records the
/// request it was handed — lets a test assert the context the builder
/// produced actually reached the model.
actor FakePersonalAIModelProvider: PersonalAIModelProviding {
    private(set) var requests: [PersonalAIGenerationRequest] = []
    private let reply: String
    private let error: Error?
    let provider: PersonalAIGenerationResult.Provider

    init(reply: String = "OK.", error: Error? = nil, provider: PersonalAIGenerationResult.Provider = .fake) {
        self.reply = reply
        self.error = error
        self.provider = provider
    }

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        requests.append(request)
        if let error { throw error }
        return PersonalAIGenerationResult(
            text: reply,
            provider: provider,
            usedPersonalization: request.personalContext.hasPersonalization
        )
    }

    var lastRequest: PersonalAIGenerationRequest? { requests.last }
}

struct FakePersonalAIError: Error, Equatable { var message: String }

/// A `MemoryExtracting` that always throws / returns nothing — used to prove
/// a Personal AI failure is contained.
struct ThrowingMemoryExtractor: MemoryExtracting {
    func extract(
        from exchange: PersonalAIExchange,
        existing: [MemoryRecord],
        excludedConversationIDs: Set<UUID>,
        memoryEnabled: Bool
    ) async -> [MemoryCandidate] {
        []
    }
}

/// A `PersonalAIContextBuilding` that records every request — used to prove
/// Personal AI Chat and the G2 seam call the SAME contract.
actor RecordingContextBuilder: PersonalAIContextBuilding {
    private(set) var requests: [PersonalAIContextRequest] = []
    private let wrapped: any PersonalAIContextBuilding

    init(wrapping: any PersonalAIContextBuilding) {
        self.wrapped = wrapping
    }

    func buildContext(_ request: PersonalAIContextRequest) async -> PersonalAIContext {
        requests.append(request)
        return await wrapped.buildContext(request)
    }

    var surfaces: [PersonalAISurface] { requests.map(\.surface) }
}

extension PersonalAIExchange {
    /// Convenience for tests.
    static func user(_ text: String, conversationID: UUID = UUID(), messageID: UUID = UUID(), at date: Date = .now) -> PersonalAIExchange {
        PersonalAIExchange(conversationID: conversationID, surface: .personalChat, timestamp: date, userText: text, userMessageID: messageID)
    }
}
