import Foundation

/// Milestone 8a: `ContinuousTranscribing` implementation backed by this
/// app's own backend (`src/realtimeTranscription/`), which in turn talks
/// to OpenAI's `gpt-live-transcribe` realtime model — see the Milestone 8
/// architecture audit. **Not wired into `EvenAIApp`/production
/// `LiveTranslationService` yet** — `GlassesSpeechTranscriber` remains the
/// live implementation until Milestone 8b makes the one-line switch (see
/// that milestone's own scope). Nothing about `LiveTranslationService`'s
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
/// `GlassesSpeechTranscriber` does today. `LiveTranslationService` (via
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

    /// One reconnect attempt per dropped connection — mirrors the
    /// backend's own single-retry policy in `session.js` exactly (see
    /// that file's `handlers.onClose`), so a transient blip on either hop
    /// (iOS<->backend here, backend<->OpenAI there) is absorbed the same
    /// way without either side needing to know about the other's policy.
    /// Reset back to `false` the moment a connection actually starts
    /// working again (`.sessionStarted`/`.finalTranscript`), so a later,
    /// independent drop still gets its own single retry.
    private var hasReconnectedSinceLastSuccess = false
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

    init(makeSocket: @escaping () async -> RealtimeTranscriptionSocket) {
        self.makeSocket = makeSocket
    }

    convenience init(apiClient: AuthenticatedAPIClient) {
        self.init(makeSocket: { URLSessionRealtimeTranscriptionSocket(apiClient: apiClient) })
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        stopInternal()
        isActive = true
        hasReconnectedSinceLastSuccess = false
        hasLoggedFirstPartialThisSession = false
        hasLoggedFirstFinalThisSession = false

        // TEMPORARY diagnostics for the Milestone 8b physical-device
        // failure ("Live Translation stopped unexpectedly") — remove
        // once root-caused. See DiagnosticTrace.swift.
        DiagnosticTrace.log("8B_TRACE", "START OpenAIRealtimeTranscriber.startTranscribing")

        let newSocket = await makeSocket()
        socket = newSocket
        do {
            let eventStream = try await newSocket.connect()
            DiagnosticTrace.log("8B_TRACE", "WS_CONNECTED backend socket connected")
            DiagnosticTrace.log("STT_SOCKET_CONNECTED_TS", "value=\(Date().timeIntervalSince1970)")
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
                    hasReconnectedSinceLastSuccess = false
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
                    hasReconnectedSinceLastSuccess = false
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
                    await handleUnexpectedClose(previousSocket: currentSocket, error: nil)
                    return
                }
            }
            guard isActive else { return }
            DiagnosticTrace.log("8B_TRACE", "WS_CLOSED event stream ended with no explicit .closed event")
            await handleUnexpectedClose(previousSocket: currentSocket, error: nil)
        } catch {
            guard isActive else { return }
            DiagnosticTrace.log("8B_TRACE", "ERROR event stream threw: \(error)")
            await handleUnexpectedClose(previousSocket: currentSocket, error: error)
        }
    }

    /// The connection ended without `stopTranscribing()` having been
    /// called — reconnect once; give up (and surface the failure to
    /// `startTranscribing`'s caller) if a reconnect was already attempted
    /// since the last successful event.
    private func handleUnexpectedClose(previousSocket: RealtimeTranscriptionSocket, error: Error?) async {
        guard isActive else { return }
        await previousSocket.close()

        guard !hasReconnectedSinceLastSuccess else {
            DiagnosticTrace.log("8B_TRACE", "STOP reason=second consecutive disconnect, giving up: \(String(describing: error))")
            continuation?.finish(throwing: error ?? RealtimeTranscriptionSocketError.notConnected)
            stopInternal()
            return
        }
        hasReconnectedSinceLastSuccess = true
        reconnectCount += 1
        DiagnosticTrace.log("8B_TRACE", "reconnect attempt starting (previous error=\(String(describing: error)))")
        DiagnosticTrace.log("STT_RECONNECT_COUNT", "value=\(reconnectCount)")

        let newSocket = await makeSocket()
        socket = newSocket
        do {
            let eventStream = try await newSocket.connect()
            DiagnosticTrace.log("8B_TRACE", "WS_CONNECTED (reconnect) backend socket connected")
            DiagnosticTrace.log("STT_SOCKET_CONNECTED_TS", "value=\(Date().timeIntervalSince1970)")
            eventConsumerTask = Task { [weak self] in
                await self?.consume(eventStream, from: newSocket)
            }
        } catch {
            DiagnosticTrace.log("8B_TRACE", "STOP reason=reconnect's own connect() threw: \(error)")
            continuation?.finish(throwing: error)
            stopInternal()
        }
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
