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

        // TEMPORARY diagnostics for the Milestone 8b physical-device
        // failure ("Live Translation stopped unexpectedly") — remove
        // once root-caused. See DiagnosticTrace.swift.
        DiagnosticTrace.log("8B_TRACE", "START OpenAIRealtimeTranscriber.startTranscribing")

        let newSocket = await makeSocket()
        socket = newSocket
        do {
            let eventStream = try await newSocket.connect()
            DiagnosticTrace.log("8B_TRACE", "WS_CONNECTED backend socket connected")
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
            pcmConsumerTask = Task { [weak self] in
                for await data in pcmUpdates {
                    guard let self, self.isActive else { break }
                    if !hasLoggedFirstPCM {
                        hasLoggedFirstPCM = true
                        DiagnosticTrace.log("8B_TRACE", "FIRST_PCM forwarding first PCM chunk, bytes=\(data.count)")
                    }
                    try? await newSocket.sendPCM(data)
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
                    continuation?.yield(.partial(text))
                case .finalTranscript(let text):
                    hasReconnectedSinceLastSuccess = false
                    // TEMPORARY — upstream-path diagnostic. Remove once
                    // root-caused. See DiagnosticTrace.swift.
                    DiagnosticTrace.log("UPSTREAM_TRACE", "STT_FINAL text=\"\(text.prefix(60))\"")
                    DiagnosticTrace.log("8B_TRACE", "FINAL_CALLBACK yielding final transcript, length=\(text.count)")
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
        DiagnosticTrace.log("8B_TRACE", "reconnect attempt starting (previous error=\(String(describing: error)))")

        let newSocket = await makeSocket()
        socket = newSocket
        do {
            let eventStream = try await newSocket.connect()
            DiagnosticTrace.log("8B_TRACE", "WS_CONNECTED (reconnect) backend socket connected")
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
