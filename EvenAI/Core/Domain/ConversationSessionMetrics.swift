import Foundation

/// Plain, directly-testable accumulator for one Live Translation
/// session's audio/STT/display reliability counters (Conversation Mode
/// follow-up, Section 6). `AIConversationEngine` owns one instance and
/// mutates its fields directly as events happen; `DiagnosticTrace` only
/// ever *renders* a snapshot of it into `CONVERSATION_SESSION_METRICS` —
/// it is never the primary way this data gets verified. Tests call
/// `AIConversationEngine.currentSessionMetrics()` and assert on these
/// fields directly, with no need to intercept console output (this
/// codebase's `DiagnosticTrace` has no test-capture hook, and inventing
/// one just to verify counters would be solving the wrong problem — the
/// counters themselves needed to be a real value, not log-string
/// parsing).
///
/// Deliberately a plain `Sendable`/`Equatable` struct, not a class: a
/// snapshot handed to a test is a frozen copy, immune to later mutation
/// on the service's own (MainActor-isolated) instance.
struct ConversationSessionMetrics: Sendable, Equatable {
    var audioChunkCount = 0
    var audioByteCount = 0
    var audioGapCount = 0
    var audioMaxGapMs = 0
    /// A SUSPECTED-drop estimate only — see `AIConversationEngine
    /// .recordAudioChunk(_:)`'s own doc comment for why an exact count
    /// is structurally impossible given what the SDK provides (no
    /// per-chunk sequence number or embedded capture timestamp).
    var audioSuspectedDroppedChunks = 0
    /// Filled in from `ContinuousTranscribing.reconnectCount` (an
    /// `async` property) only at snapshot time — see
    /// `AIConversationEngine.currentSessionMetrics()`. Stays `0` on
    /// any snapshot taken before that fill-in happens.
    var sttReconnectCount = 0
    var utteranceCount = 0
    var finalTranscriptCount = 0
    /// Filled in from `agentContextStore.session.turns.count` at
    /// snapshot time — a turn only ever stays in `session.turns` if its
    /// translation actually succeeded (a failed/timed-out/cancelled
    /// translation removes its draft turn), so this count already IS
    /// "how many turns were actually persisted this session."
    var finalTurnsPersistedCount = 0
    var translationFailureCount = 0
    /// Counts a `glassesTransport.displayPages(...)` call throwing,
    /// across every call site (`displayPartial`/`processTurn`/
    /// `generateSuggestedReplies`/`redisplayLiveContent`/
    /// `renderHistoryViewport`).
    var displayFailureCount = 0
    /// Bounded (never unbounded) rolling sample of each successfully-
    /// displayed turn's end-to-end "first useful translation" latency —
    /// see `recordFirstUsefulTranslationSample(_:cap:)`. For any session
    /// under the cap, `avgFirstUsefulTranslationMs`/
    /// `medianFirstUsefulTranslationMs` are exact, not approximations;
    /// for a longer session, they reflect only the most recent samples,
    /// which is also the more operationally useful number for someone
    /// checking in on a long-running meeting.
    private(set) var firstUsefulTranslationSamplesMs: [Int] = []

    mutating func recordFirstUsefulTranslationSample(_ ms: Int, cap: Int = 50) {
        firstUsefulTranslationSamplesMs.append(ms)
        if firstUsefulTranslationSamplesMs.count > cap {
            firstUsefulTranslationSamplesMs.removeFirst()
        }
    }

    var avgFirstUsefulTranslationMs: Int {
        guard !firstUsefulTranslationSamplesMs.isEmpty else { return 0 }
        return firstUsefulTranslationSamplesMs.reduce(0, +) / firstUsefulTranslationSamplesMs.count
    }

    var medianFirstUsefulTranslationMs: Int {
        let samples = firstUsefulTranslationSamplesMs.sorted()
        guard !samples.isEmpty else { return 0 }
        if samples.count % 2 == 0 {
            return (samples[samples.count / 2 - 1] + samples[samples.count / 2]) / 2
        }
        return samples[samples.count / 2]
    }
}
