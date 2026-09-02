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

/// A `PersonalAIContextBuilding` that returns a scripted `PersonalAIContext`,
/// records every request, and can be made to hang (for enrichment-timeout /
/// cancellation tests). Used by the Phase 3 G2 reply-enrichment suites.
actor ScriptedContextBuilder: PersonalAIContextBuilding {
    private(set) var requests: [PersonalAIContextRequest] = []
    private(set) var buildStartedCount = 0
    private(set) var buildFinishedCount = 0
    private let result: PersonalAIContext
    /// Delay before returning — model a slow retrieval. `nil` = return at once.
    private let delay: Duration?

    init(result: PersonalAIContext = .empty, delay: Duration? = nil) {
        self.result = result
        self.delay = delay
    }

    func buildContext(_ request: PersonalAIContextRequest) async -> PersonalAIContext {
        requests.append(request)
        buildStartedCount += 1
        if let delay {
            // `Task.sleep` is a cancellation point — a cancelled enrichment
            // stops here rather than spinning for the full delay.
            try? await Task.sleep(for: delay)
        }
        buildFinishedCount += 1
        return result
    }

    var surfaces: [PersonalAISurface] { requests.map(\.surface) }
    var lastRequest: PersonalAIContextRequest? { requests.last }

    // MARK: canned results

    /// A context with genuine personalisation (non-empty rendered block).
    static func personalised(_ block: String = "Response style: keep it short.") -> PersonalAIContext {
        PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: block,
            systemPromptText: block, memoryDisabled: false, buildTrace: ["scripted"]
        )
    }

    /// A context reporting memory globally disabled.
    static var memoryDisabled: PersonalAIContext {
        PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: "",
            systemPromptText: "Personal memory is turned off …", memoryDisabled: true, buildTrace: ["memoryDisabled"]
        )
    }
}
