import Foundation

/// Milestone 8a: `ContinuousTranscribing` implementation backed by this
/// app's own backend (`src/realtimeTranscription/`), which in turn talks
/// to OpenAI's `gpt-live-transcribe` realtime model — see the Milestone 8
/// architecture audit. **Not wired into `EvenAIApp`/production
/// `AIConversationEngine` yet** — `GlassesSpeechTranscriber` remains the
/// live implementation until Milestone 8b makes the one-line switch (see
/// that milestone's own scope). Nothing about `AIConversationEngine`'s
/// integration needs to change to do that: this type conforms to the
/// exact same `ContinuousTranscribing` protocol, unchanged.
///
/// Multilingual scope (English/German/Polish/Ukrainian) is configured
/// entirely on the backend (`src/realtimeTranscription/openaiClient.js`'s
/// `SUPPORTED_LANGUAGES`) — this class has no locale/language
/// configuration of its own at all, unlike `GlassesSpeechTranscriber`'s
/// hardcoded `en-US`, and never runs more than one recognizer/session
/// concurrently (there is exactly one `RealtimeTranscriptionSocket` open
/// at a time — `handleUnexpectedClose(...)` replaces it, never adds a
/// second one alongside it).
///
/// Ukrainian-vs-foreign filtering is deliberately NOT here: this class
/// only reports whatever text the backend finalizes, exactly like
/// `GlassesSpeechTranscriber` does today. `AIConversationEngine` (via
/// the existing, unchanged `LanguageTranslating.detectedLanguageCode(for:)`)
/// remains the one place that decides whether a given final becomes a
/// live-conversation `ConversationTurn`.
///
/// `@MainActor` + `@unchecked Sendable`: mirrors `GlassesSpeechTranscriber`'s
/// own isolation pattern.
@MainActor
final class OpenAIRealtimeTranscriber: ContinuousTranscribing, @unchecked Sendable {
    private let makeSocket: () async -> RealtimeTranscriptionSocket

    private var isActive = false
    private var socket: RealtimeTranscriptionSocket?
    private var pcmConsumerTask: Task<Void, Never>?
    private var eventConsumerTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    /// The most recent `language_info` the backend reported, if any —
    /// captured for future use/observability only. `ContinuousTranscribing`'s
    /// contract is unchanged (finals only), so this is deliberately never
    /// surfaced through `startTranscribing`'s own output stream — see
    /// this type's doc comment on why Ukrainian filtering stays out of
    /// this layer regardless of what's available here.
    private(set) var lastKnownLanguages: [String]?

    /// Bounded reconnect with backoff (Conversation Mode hardening
    /// follow-up — physical-device "Live Translation stopped
    /// unexpectedly" investigation): a single dropped connection used to
    /// get exactly ONE retry attempt before giving up and ending the
    /// whole Live Translation session — a real BLE/cellular/backend
    /// hiccup only has to happen twice in a row (very plausible on a
    /// three-hop chain: G2↔phone BLE, phone↔backend WebSocket,
    /// backend↔OpenAI) to kill an otherwise-healthy session. Now bounded
    /// to `maxConsecutiveReconnectAttempts` attempts with increasing
    /// backoff between them (first retry immediate, then growing) —
    /// generous enough to ride out a real transient blip, still bounded
    /// so a genuinely dead connection surfaces in finite time rather
    /// than retrying forever. Overridable only by tests (see `init`),
    /// which need a much smaller bound/near-zero backoff to stay fast.
    private let maxConsecutiveReconnectAttempts: Int
    private let reconnectBackoffSchedule: [Duration]
    /// How many reconnect attempts have been made since the last
    /// successful event (`.sessionStarted`/`.finalTranscript`) — reset
    /// to `0` the moment a connection actually starts working again, so
    /// a later, independent drop gets its own full bounded budget.
    private var consecutiveReconnectAttempts = 0
    /// Lifetime count of reconnect attempts this instance has made —
    /// `STT_RECONNECT_COUNT` (Conversation Mode audio-reliability
    /// instrumentation). Never reset between sessions (this instance is
    /// constructed once, in `EvenAIApp`) — a rising count across a long
    /// meeting is itself a useful reliability signal.
    private(set) var reconnectCount = 0
    /// Audio-reliability instrumentation (Section 2/3): whether
    /// `STT_FIRST_PARTIAL_TS`/`STT_FIRST_FINAL_TS` have already logged
    /// for the CURRENT `startTranscribing(pcmUpdates:)` session — reset
    /// there, so each new session gets its own first-partial/first-final
    /// timestamp rather than only ever logging once per process
    /// lifetime. Deliberately NOT reset on a mid-session reconnect
    /// (`handleUnexpectedClose`'s own retry path) — "first partial/final
    /// of this Live Translation session," not "of this specific socket
    /// connection."
    private var hasLoggedFirstPartialThisSession = false
    private var hasLoggedFirstFinalThisSession = false

    init(
        makeSocket: @escaping () async -> RealtimeTranscriptionSocket,
        maxConsecutiveReconnectAttempts: Int = 5,
        reconnectBackoffSchedule: [Duration] = [.zero, .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]
    ) {
        self.makeSocket = makeSocket
        self.maxConsecutiveReconnectAttempts = maxConsecutiveReconnectAttempts
        self.reconnectBackoffSchedule = reconnectBackoffSchedule
    }

    convenience init(apiClient: AuthenticatedAPIClient) {
        self.init(makeSocket: { URLSessionRealtimeTranscriptionSocket(apiClient: apiClient) })
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        stopInternal()
        isActive = true
        consecutiveReconnectAttempts = 0
        hasLoggedFirstPartialThisSession = false
        hasLoggedFirstFinalThisSession = false

        // TEMPORARY diagnostics for the Milestone 8b physical-device
        // failure ("Live Translation stopped unexpectedly") — remove
        // once root-caused. See DiagnosticTrace.swift.
        DiagnosticTrace.log("8B_TRACE", "START OpenAIRealtimeTranscriber.startTranscribing")

        let newSocket = await makeSocket()
        socket = newSocket
        do {
            // `connect()` returning here proves only that the WS task
            // was resumed (and, as of this fix, that a session was
            // successfully recovered/attached) — NOT that the WebSocket
            // upgrade itself succeeded. See
            // `URLSessionRealtimeTranscriptionSocket.connect()`'s own
            // doc comment: the genuine confirmation is
            // `WS_HANDSHAKE_CONFIRMED`, logged separately, once
            // `pump(_:into:)`'s first `receive()` call actually
            // succeeds. Logging this checkpoint as "WS_CONNECTED" was
            // the exact misleading trace that made a doomed-to-fail
            // (401) connection attempt look identical to a healthy one
            // in the physical-device trace that led to this fix.
            let eventStream = try await newSocket.connect()
            DiagnosticTrace.log("8B_TRACE", "SOCKET_TASK_RESUMED handshake not yet confirmed — see WS_HANDSHAKE_CONFIRMED")
            DiagnosticTrace.log("STT_SOCKET_TASK_RESUMED_TS", "value=\(Date().timeIntervalSince1970)")
            return try buildStream(from: eventStream, pcmUpdates: pcmUpdates, socket: newSocket)
        } catch {
            DiagnosticTrace.log("8B_TRACE", "ERROR connect() threw before any stream existed: \(error)")
            throw error
        }
    }

    private func buildStream(
        from eventStream: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>,
        pcmUpdates: AsyncStream<Data>,
        socket newSocket: RealtimeTranscriptionSocket
    ) throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        return AsyncThrowingStream { continuation in
            self.continuation = continuation

            var hasLoggedFirstPCM = false
            // Created exactly ONCE per `startTranscribing(pcmUpdates:)`
            // call (never recreated by `handleUnexpectedClose`'s
            // reconnect path — `pcmUpdates` is a single-consumer
            // `AsyncStream`, and running a second `for await` over it
            // concurrently would silently split its elements between two
            // competing consumers, not deliver every chunk to both). It
            // stays alive across an unlimited number of reconnects by
            // routing every chunk through `self.socket` — read FRESH on
            // every iteration, never the `newSocket` parameter captured
            // here — since `socket` is reassigned to the new connection
            // the moment a reconnect succeeds (both in
            // `startTranscribing` and in `handleUnexpectedClose`). Fixes
            // a real bug found auditing reconnect behavior: routing to
            // the captured `newSocket` instead meant every PCM chunk
            // kept being silently sent (`try?`) to the ORIGINAL, by-then
            // -closed socket after any reconnect — the new connection's
            // event stream could still work, but the backend would never
            // receive another byte of audio to transcribe from it.
            pcmConsumerTask = Task { [weak self] in
                for await data in pcmUpdates {
                    guard let self, self.isActive else { break }
                    if !hasLoggedFirstPCM {
                        hasLoggedFirstPCM = true
                        DiagnosticTrace.log("8B_TRACE", "FIRST_PCM forwarding first PCM chunk, bytes=\(data.count)")
                        DiagnosticTrace.log("STT_FIRST_AUDIO_SENT_TS", "value=\(Date().timeIntervalSince1970)")
                    }
                    guard let currentSocket = self.socket else { continue }
                    try? await currentSocket.sendPCM(data)
                }
            }

            eventConsumerTask = Task { [weak self] in
                await self?.consume(eventStream, from: newSocket)
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stopInternal() }
            }
        }
    }

    func stopTranscribing() async {
        stopInternal()
    }

    /// Runs for the lifetime of one `RealtimeTranscriptionSocket`
    /// connection. Returning from this method always means either the
    /// session ended intentionally (`isActive` already false) or a
    /// reconnect was already handed off to a new `eventConsumerTask` —
    /// never a silently-abandoned connection.
    private func consume(_ events: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>, from currentSocket: RealtimeTranscriptionSocket) async {
        var hasLoggedFirstEvent = false
        do {
            for try await event in events {
                guard isActive else { return }
                if !hasLoggedFirstEvent {
                    hasLoggedFirstEvent = true
                    DiagnosticTrace.log("8B_TRACE", "FIRST_EVENT \(event)")
                }
                switch event {
                case .sessionStarted:
                    consecutiveReconnectAttempts = 0
                case .partialTranscript(let text):
                    // Streaming-translation path (major performance pass):
                    // previously discarded — see TranscriptionUpdate's doc
                    // comment for why surfacing this is what actually makes
                    // "translation appears near-real-time" possible.
                    DiagnosticTrace.log("LATENCY_TRACE", "AUDIO_TO_PARTIAL_TS value=\(Date().timeIntervalSince1970)")
                    if !hasLoggedFirstPartialThisSession {
                        hasLoggedFirstPartialThisSession = true
                        DiagnosticTrace.log("STT_FIRST_PARTIAL_TS", "value=\(Date().timeIntervalSince1970)")
                    }
                    continuation?.yield(.partial(text))
                case .finalTranscript(let text):
                    consecutiveReconnectAttempts = 0
                    // TEMPORARY — upstream-path diagnostic. Remove once
                    // root-caused. See DiagnosticTrace.swift.
                    DiagnosticTrace.log("UPSTREAM_TRACE", "STT_FINAL text=\"\(text.prefix(60))\"")
                    DiagnosticTrace.log("8B_TRACE", "FINAL_CALLBACK yielding final transcript, length=\(text.count)")
                    if !hasLoggedFirstFinalThisSession {
                        hasLoggedFirstFinalThisSession = true
                        DiagnosticTrace.log("STT_FIRST_FINAL_TS", "value=\(Date().timeIntervalSince1970)")
                    }
                    continuation?.yield(.final(text))
                case .languageInfo(let languages):
                    lastKnownLanguages = languages
                case .providerError(let message):
                    DiagnosticTrace.log("8B_TRACE", "ERROR providerError (non-fatal): \(message)")
                    // Non-fatal — same "log and keep going" policy
                    // GlassesSpeechTranscriber already applies to a
                    // recognition-session-boundary error: one failure
                    // doesn't end an otherwise-healthy stream.
                    continue
                case .closed(let reason):
                    DiagnosticTrace.log("8B_TRACE", "WS_CLOSED reason=\(reason ?? "nil")")
                    DiagnosticTrace.log("STT_SOCKET_CLOSED", "reason=\(reason ?? "nil") explicit=true")
                    await handleUnexpectedClose(previousSocket: currentSocket, error: nil)
                    return
                }
            }
            guard isActive else { return }
            DiagnosticTrace.log("8B_TRACE", "WS_CLOSED event stream ended with no explicit .closed event")
            DiagnosticTrace.log("STT_SOCKET_CLOSED", "reason=streamEndedWithNoExplicitClose explicit=false")
            await handleUnexpectedClose(previousSocket: currentSocket, error: nil)
        } catch {
            guard isActive else { return }
            DiagnosticTrace.log("8B_TRACE", "ERROR event stream threw: \(error)")
            DiagnosticTrace.log("STT_SOCKET_CLOSED", "reason=eventStreamThrew error=\(error) explicit=false")
            await handleUnexpectedClose(previousSocket: currentSocket, error: error)
        }
    }

    /// The connection ended without `stopTranscribing()` having been
    /// called — reconnect with bounded retries and backoff (see
    /// `maxConsecutiveReconnectAttempts`/`reconnectBackoffSchedule`'s own
    /// doc comments); give up (and surface the failure to
    /// `startTranscribing`'s caller) only once every attempt in the
    /// budget has failed. A loop, not recursion, so an exhausted budget
    /// can never grow the call stack.
    private func handleUnexpectedClose(previousSocket: RealtimeTranscriptionSocket, error: Error?) async {
        guard isActive else { return }
        await previousSocket.close()

        var lastError = error
        while consecutiveReconnectAttempts < maxConsecutiveReconnectAttempts {
            guard isActive else { return }
            let attemptNumber = consecutiveReconnectAttempts + 1
            consecutiveReconnectAttempts = attemptNumber
            reconnectCount += 1
            let backoff = reconnectBackoffSchedule[min(attemptNumber - 1, reconnectBackoffSchedule.count - 1)]
            DiagnosticTrace.log(
                "STT_RECONNECT_STARTED",
                "attempt=\(attemptNumber)/\(maxConsecutiveReconnectAttempts) backoff=\(backoff) previousError=\(String(describing: lastError))"
            )
            DiagnosticTrace.log("STT_RECONNECT_COUNT", "value=\(reconnectCount)")

            if backoff > .zero {
                try? await Task.sleep(for: backoff)
                guard isActive else { return }
            }

            let newSocket = await makeSocket()
            socket = newSocket
            do {
                // Same caveat as the initial connection (see
                // `startTranscribing`'s own comment): this only proves
                // the reconnect attempt's task was resumed, not that its
                // handshake succeeded — genuine confirmation is
                // `WS_HANDSHAKE_CONFIRMED`, logged separately once this
                // new socket's own `pump(_:into:)` actually receives
                // something.
                let eventStream = try await newSocket.connect()
                DiagnosticTrace.log("8B_TRACE", "SOCKET_TASK_RESUMED (reconnect) handshake not yet confirmed")
                DiagnosticTrace.log("STT_SOCKET_TASK_RESUMED_TS", "value=\(Date().timeIntervalSince1970)")
                DiagnosticTrace.log("STT_RECONNECT_ATTEMPT_RESUMED", "attempt=\(attemptNumber)")
                eventConsumerTask = Task { [weak self] in
                    await self?.consume(eventStream, from: newSocket)
                }
                return
            } catch {
                DiagnosticTrace.log("8B_TRACE", "reconnect attempt \(attemptNumber) connect() threw: \(error)")
                await newSocket.close()
                lastError = error
            }
        }

        DiagnosticTrace.log(
            "STT_RECONNECT_EXHAUSTED",
            "attempts=\(consecutiveReconnectAttempts) lastError=\(String(describing: lastError))"
        )
        continuation?.finish(throwing: lastError ?? RealtimeTranscriptionSocketError.notConnected)
        stopInternal()
    }

    private func stopInternal() {
        if isActive {
            DiagnosticTrace.log("8B_TRACE", "STOP reason=stopTranscribing()/stream terminated")
        }
        isActive = false
        pcmConsumerTask?.cancel()
        pcmConsumerTask = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        continuation?.finish()
        continuation = nil

        guard let socketToClose = socket else { return }
        socket = nil
        Task { await socketToClose.close() }
    }
}
