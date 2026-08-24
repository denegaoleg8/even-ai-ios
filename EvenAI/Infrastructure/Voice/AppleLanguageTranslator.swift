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

    /// Returns the next queued item, or `nil` once this `runSession(_:)`
    /// call's own `Task` has been cancelled — never hangs forever on a
    /// stuck `CheckedContinuation` the way a plain `await
    /// withCheckedContinuation { ... }` would (see
    /// `waitForArrivalOrCancellation()`'s own doc comment for why that
    /// distinction matters now more than it used to).
    private func nextPendingTranslation() async -> PendingTranslation? {
        while true {
            if !pendingTranslations.isEmpty {
                return pendingTranslations.removeFirst()
            }
            guard !Task.isCancelled else { return nil }
            await waitForArrivalOrCancellation()
            if Task.isCancelled { return nil }
        }
    }

    /// Root-cause fix (major performance pass — language-selection state
    /// bug): `RootView` now reconfigures/recreates the real
    /// `TranslationSession` whenever `LiveTranslationService
    /// .resolvedSourceLanguageCode` changes (an explicit EN/DE/PL switch,
    /// or Auto's first lock) — a LEGITIMATE, expected event now, not a
    /// rare edge case. When that happens, `.translationTask`'s modifier
    /// cancels the OLD `runSession(_:)` call's `Task`. A plain `await
    /// withCheckedContinuation { pendingArrival = $0 }` does NOT respond
    /// to that cancellation on its own — `CheckedContinuation` only ever
    /// resumes when something explicitly calls `.resume()` — so if the
    /// queue happened to be idle (the common case: reconfiguration is a
    /// deliberate user action, not something that happens mid-utterance),
    /// `runSession(_:)`'s loop would hang forever on this exact await,
    /// NEVER reaching its own `while !Task.isCancelled` recheck — a
    /// leaked, permanently-blocked Task. Worse: since `AppleLanguageTranslator`
    /// is one shared, long-lived instance (constructed once in
    /// `EvenAIApp`), the NEXT `runSession(_:)` call (for the new session)
    /// would then run CONCURRENTLY with this leaked, still-alive old one
    /// — two consumers racing to dequeue from the same
    /// `pendingTranslations` array. `withTaskCancellationHandler` is what
    /// actually closes this gap: `onCancel` fires the moment cancellation
    /// is requested (from an unspecified, `Sendable`-only context, hence
    /// the `Task { @MainActor in ... }` hop back) and proactively resumes
    /// the parked continuation, letting the loop wake up and see
    /// `Task.isCancelled == true` immediately instead of never.
    private func waitForArrivalOrCancellation() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingArrival = continuation
            }
        } onCancel: {
            Task { @MainActor [self] in
                self.resumeArrivalIfWaiting()
            }
        }
    }

    private func resumeArrivalIfWaiting() {
        pendingArrival?.resume()
        pendingArrival = nil
    }

    /// Call from `RootView`'s `.translationTask(_:action:)` closure:
    /// `.translationTask(configuration) { session in await
    /// translator.runSession(session) }`. Runs until the task is
    /// cancelled (the configuration changing — see
    /// `nextPendingTranslation()`'s own doc comment — or the view
    /// disappearing), so it naturally stops resolving requests once Live
    /// Translation is no longer on screen. Any request still queued at
    /// that point is failed immediately with `SessionEndedError` — never
    /// left to silently hang until a caller's own external timeout
    /// (`LiveTranslationService.translateWithTimeout(_:from:)`'s 8s)
    /// eventually recovers it. This is what makes a deliberate language-
    /// mode switch "immediately recover the current session" rather than
    /// stalling any translation that happened to be mid-flight for up to
    /// 8 extra seconds.
    func runSession(_ session: TranslationSession) async {
        while !Task.isCancelled {
            guard let pending = await nextPendingTranslation() else { break }
            do {
                let targetText = try await translate(pending.text, using: session)
                pending.continuation.resume(returning: targetText)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
        failAllPending()
    }

    private func failAllPending() {
        guard !pendingTranslations.isEmpty else { return }
        let stillPending = pendingTranslations
        pendingTranslations.removeAll()
        for pending in stillPending {
            pending.continuation.resume(throwing: SessionEndedError())
        }
    }

    private struct SessionEndedError: Error, CustomStringConvertible {
        var description: String { "the on-device translation session ended (reconfigured or torn down) before this request was reached" }
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
