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

    /// Bounds each individual `session.translate(_:)` call inside
    /// `runSession(_:)`'s own loop — NOT the same thing as a caller's own
    /// timeout on `translateToUkrainian(_:from:)` (see
    /// `LiveTranslationService.translateWithTimeout(_:from:)`), and not
    /// redundant with it. `pendingTranslations` is a single-consumer FIFO
    /// queue: `runSession(_:)` dequeues one item and awaits its
    /// `session.translate(_:)` call before it ever looks at the next
    /// queued item. A caller-side timeout only makes THAT CALLER stop
    /// waiting — it does nothing to un-stick `runSession(_:)`'s own loop,
    /// which is still sitting on the same stuck `session.translate(_:)`
    /// call for the abandoned item. Confirmed as the actual root cause of
    /// "Live Translation hangs on one phrase and never continues" for
    /// this specific implementation: every later translation request,
    /// however unrelated, funnels through this one queue and would never
    /// even be dequeued, let alone attempted, while the loop is wedged.
    /// Racing a timeout around each dequeued item, right here, is what
    /// actually frees the loop to move on to the next one.
    private static let perCallTimeout: Duration = .seconds(8)

    private struct PendingTranslation {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var pendingTranslations: [PendingTranslation] = []
    private var pendingArrival: CheckedContinuation<Void, Never>?

    nonisolated init() {}

    func detectedLanguageCode(for text: String) async -> String? {
        // Measured directly against the real NLLanguageRecognizer (not
        // assumed): "hello" scores only ~0.13 confidence for English, its
        // actual language ("no"/"goodbye" score even lower and get
        // assigned to entirely wrong languages — Portuguese, Danish —
        // both still under the 0.6 bar below; "okay" scores ~0.39, also
        // under it). A single short, common word simply doesn't carry
        // enough statistical signal for a general-purpose n-gram model —
        // raising/lowering confidenceThreshold can't fix this without
        // either still rejecting these exact words or accepting
        // genuinely ambiguous/noisy input elsewhere. See
        // `CommonShortUtterances`'s own doc comment for why this table is
        // shared with `LiveTranslationService`'s Auto-lock hysteresis,
        // not private to this file.
        if let knownLanguage = CommonShortUtterances.language(for: text) {
            return knownLanguage
        }

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
                let targetText = try await translate(pending.text, using: session)
                pending.continuation.resume(returning: targetText)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
    }

    /// See `perCallTimeout`'s doc comment for why this — not a plain
    /// `try await session.translate(text).targetText` — is what actually
    /// keeps `runSession(_:)`'s single-consumer loop from getting
    /// permanently wedged behind one stuck call.
    private func translate(_ text: String, using session: TranslationSession) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await session.translate(text).targetText }
            group.addTask {
                try await Task.sleep(for: Self.perCallTimeout)
                throw PerCallTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct PerCallTimeoutError: Error, CustomStringConvertible {
        var description: String { "on-device translation call timed out" }
    }
}
