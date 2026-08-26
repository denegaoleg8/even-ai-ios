import Foundation
@testable import EvenAI

/// Records every call it receives (the turn + context passed in) and
/// returns a scripted result — lets a test both assert on what
/// `AIConversationEngine` sent in, and control what comes back
/// (replies, or a thrown error).
actor FakeSuggestedReplyGenerator: SuggestedReplyGenerating {
    struct Call {
        let turn: ConversationTurn
        let context: SuggestedReplyContext
    }

    private(set) var calls: [Call] = []
    /// Keyed by `turn.originalText` so a single fake instance can return
    /// different replies for different turns in the same test (see
    /// "multiple turns don't mix replies").
    private let repliesByOriginalText: [String: [SuggestedReply]]
    private let defaultReplies: [SuggestedReply]
    private let error: Error?

    init(
        repliesByOriginalText: [String: [SuggestedReply]] = [:],
        defaultReplies: [SuggestedReply] = [],
        error: Error? = nil
    ) {
        self.repliesByOriginalText = repliesByOriginalText
        self.defaultReplies = defaultReplies
        self.error = error
    }

    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        calls.append(Call(turn: turn, context: context))
        if let error {
            throw error
        }
        return repliesByOriginalText[turn.originalText] ?? defaultReplies
    }
}

struct FakeSuggestedReplyGenerationError: Error, Equatable {
    let message: String
}

/// A generator whose `generateReplies` call, keyed by `turn.originalText`,
/// suspends until the test explicitly calls `release(_:)` — lets a test
/// deterministically construct "turn A's reply generation is still in
/// flight when turn B arrives and finishes first," which is what actually
/// exercises `AIConversationEngine`'s "newest turn always wins on G2"
/// guard (see `generateSuggestedReplies(for:)`). Calling `release(_:)`
/// before the call ever starts is safe — it's recorded and the call
/// returns immediately once it does start.
actor GatedSuggestedReplyGenerator: SuggestedReplyGenerating {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasedKeys: Set<String> = []
    private let repliesByOriginalText: [String: [SuggestedReply]]

    init(repliesByOriginalText: [String: [SuggestedReply]] = [:]) {
        self.repliesByOriginalText = repliesByOriginalText
    }

    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        await waitUntilReleased(turn.originalText)
        return repliesByOriginalText[turn.originalText] ?? []
    }

    private func waitUntilReleased(_ key: String) async {
        if releasedKeys.contains(key) { return }
        await withCheckedContinuation { continuation in
            continuations[key] = continuation
        }
    }

    func release(_ key: String) {
        releasedKeys.insert(key)
        continuations[key]?.resume()
        continuations[key] = nil
    }
}
