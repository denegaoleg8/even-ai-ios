import Foundation
import NaturalLanguage
// `@preconcurrency`: this SDK's `TranslationSession` predates Swift 6
// strict-concurrency annotations — without this, Swift treats every use of
// it (even fully same-actor, e.g. `runSession(_:)` calling
// `session.translate(_:)` on the very session it was just handed) as an
// unsafe cross-isolation "send", which it structurally cannot be: the
// session never leaves the single async context it's created and consumed
// in. `@preconcurrency` downgrades that framework-gap diagnostic without
// weakening strict checking anywhere else in this file.
@preconcurrency import Translation

/// `LanguageTranslating` implementation using only first-party Apple
/// frameworks — `NaturalLanguage` for detection, `Translation` for
/// rendering into Ukrainian. Both run entirely on-device: no audio or
/// transcript text from this feature is ever sent to Railway/OpenAI or any
/// other backend.
///
/// The `Translation` framework only vends a usable `TranslationSession`
/// through SwiftUI's `.translationTask(_:action:)` modifier — there is no
/// way to construct one directly, and `TranslationSession` isn't
/// `Sendable`, so it can't be stored in a property and used later (that
/// was tried and rejected — Swift 6 strict concurrency correctly flags it
/// as a data-race risk). Instead, `runSession(_:)` runs for the lifetime
/// of `LiveTranslationView`'s `.translationTask` closure and is the *only*
/// place `session` is ever touched: it drains `translateToUkrainian`
/// requests as they arrive and resolves each one with
/// `session.translate(_:)` from directly within that same closure/task.
/// Everything crossing into/out of this type elsewhere (`String`,
/// `CheckedContinuation`) is `Sendable`.
@MainActor
final class AppleLanguageTranslator: LanguageTranslating, @unchecked Sendable {
    /// Below this confidence, detection is treated as too uncertain to act
    /// on — see `LanguageTranslating.detectedLanguageCode(for:)`'s "do
    /// nothing rather than produce noisy output" contract.
    private static let confidenceThreshold = 0.6

    private struct PendingTranslation {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var pendingTranslations: [PendingTranslation] = []
    private var pendingArrival: CheckedContinuation<Void, Never>?

    nonisolated init() {}

    func detectedLanguageCode(for text: String) async -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        guard confidence >= Self.confidenceThreshold else { return nil }
        return dominant.rawValue
    }

    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(PendingTranslation(text: text, continuation: continuation))
        }
    }

    private func enqueue(_ pending: PendingTranslation) {
        pendingTranslations.append(pending)
        pendingArrival?.resume()
        pendingArrival = nil
    }

    private func nextPendingTranslation() async -> PendingTranslation {
        while true {
            if !pendingTranslations.isEmpty {
                return pendingTranslations.removeFirst()
            }
            await withCheckedContinuation { pendingArrival = $0 }
        }
    }

    /// Call from `LiveTranslationView`'s `.translationTask(_:action:)`
    /// closure: `.translationTask(configuration) { session in await
    /// translator.runSession(session) }`. Runs until the task is cancelled
    /// (the view disappearing/`translationConfiguration` changing), so it
    /// naturally stops resolving requests once Live Translation is no
    /// longer on screen; any request still pending at that point simply
    /// never resolves — `LiveTranslationViewModel` already tears down its
    /// consume loop on `stop()`, so nothing is left awaiting it.
    func runSession(_ session: TranslationSession) async {
        while !Task.isCancelled {
            let pending = await nextPendingTranslation()
            do {
                let response = try await session.translate(pending.text)
                pending.continuation.resume(returning: response.targetText)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
    }
}
