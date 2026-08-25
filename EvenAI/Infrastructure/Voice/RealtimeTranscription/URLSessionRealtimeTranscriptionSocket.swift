import Foundation

/// Real `RealtimeTranscriptionSocket` — talks to this app's own backend
/// (`GET /api/realtime-transcription`, upgraded to a WebSocket), never to
/// OpenAI or any other STT vendor directly. Authenticated exactly like
/// every REST call (`AuthenticatedAPIClient.makeWebSocketRequest`, the
/// same Bearer access token) — no second auth system, no API key of any
/// kind on this side of the connection.
///
/// `@MainActor` + `@unchecked Sendable`: mirrors `GlassesSpeechTranscriber`'s
/// own isolation pattern — all mutable state (`task`) is confined to the
/// main actor, never accessed concurrently.
@MainActor
final class URLSessionRealtimeTranscriptionSocket: RealtimeTranscriptionSocket, @unchecked Sendable {
    private static let path = "realtime-transcription"

    private let apiClient: AuthenticatedAPIClient
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?

    init(apiClient: AuthenticatedAPIClient, urlSession: URLSession = .shared) {
        self.apiClient = apiClient
        self.urlSession = urlSession
    }

    /// Root cause of the physical-device "Live Translation stopped
    /// unexpectedly" failure (traced to `NSURLErrorDomain -1011` — a
    /// non-101 WS handshake response — which the backend's own
    /// `wsServer.js` produces as a raw, bodiless `401 Unauthorized`
    /// whenever the upgrade request arrives with no `Authorization`
    /// header at all): NOTHING in this call path used to ever ensure a
    /// session existed before attaching credentials, despite
    /// `AuthenticatedAPIClient.makeWebSocketRequest`'s own doc comment
    /// already promising a caller would do exactly that. Every other
    /// authenticated call in this app gets "recover once, then attach a
    /// valid token" for free from `AuthenticatedAPIClient
    /// .performOnce`'s reactive 401→recover→retry path; a WebSocket
    /// upgrade can't be retried in place the way a REST request's 401
    /// can, so the equivalent guarantee has to be proactive, here, on
    /// every single connection attempt — the very first one AND every
    /// reconnect (each of `OpenAIRealtimeTranscriber`'s bounded retry
    /// attempts constructs a fresh `URLSessionRealtimeTranscriptionSocket`
    /// and calls `connect()` on it again).
    ///
    /// Uses `ensureSession()`, not the always-recovers `recoverSession()`
    /// this method briefly called: a second, follow-up physical-device
    /// regression (Live Translation immediately reporting a false "check
    /// your G2 connection" failure, AND normal Chat failing to open)
    /// traced back to calling the always-network-round-trip
    /// `recoverSession()` unconditionally on every one of the bounded
    /// reconnect attempts — `/auth/refresh` rotates the refresh token on
    /// every call, so repeated unconditional recovery churned the ONE
    /// session Live Translation and Chat share, far more than the
    /// original bug (a genuinely missing credential) ever required a fix
    /// for. See `ensureSession()`'s own doc comment.
    func connect() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        DiagnosticTrace.log("LIVE_START_AUTH_RECOVERY_BEGIN", "path=\(Self.path)")
        do {
            try await apiClient.ensureSession()
            DiagnosticTrace.log("LIVE_START_AUTH_RECOVERY_OK", "path=\(Self.path)")
            let state = await apiClient.currentSessionState()
            if case .ready(let type) = state {
                DiagnosticTrace.log("STT_AUTH_READY", "type=\(type.rawValue)")
            }
        } catch {
            DiagnosticTrace.log("LIVE_START_AUTH_RECOVERY_FAILED", "errorType=\(type(of: error)) errorMessage=\(error)")
            DiagnosticTrace.log("STT_AUTH_FAILED", "reason=\(error)")
            throw error
        }
        var request = await apiClient.makeWebSocketRequest(path: Self.path)
        request.url = Self.webSocketURL(from: request.url) ?? request.url

        // TEMPORARY diagnostics for the Milestone 8b physical-device
        // failure — remove once root-caused. See DiagnosticTrace.swift.
        // Never logs the token itself, only whether one is present —
        // this directly tests whether `AuthenticatedAPIClient.accessToken`
        // was actually populated (e.g. by RootView's launch-time
        // restoreSession(), or — as of the earlier fix — by the
        // `ensureSession()` call directly above) by the moment Live
        // Translation starts.
        let hasAuthHeader = request.value(forHTTPHeaderField: "Authorization") != nil
        DiagnosticTrace.log("8B_TRACE", "AUTH url=\(request.url?.absoluteString ?? "nil") hasAuthorizationHeader=\(hasAuthHeader)")

        DiagnosticTrace.log("LIVE_START_SOCKET_CREATE", "url=\(request.url?.absoluteString ?? "nil")")
        let newTask = urlSession.webSocketTask(with: request)
        task = newTask
        // Starts the task connecting asynchronously — this does NOT
        // prove the WebSocket upgrade actually succeeded (a 401, or any
        // other non-101 response, surfaces later, as `pump(_:into:)`'s
        // own `task.receive()` throwing on its very first call — see
        // that method's doc comment for the trace that actually confirms
        // a genuine handshake, `WS_HANDSHAKE_CONFIRMED`). Logging
        // "connected" from here, before that confirmation exists, is
        // exactly what made a doomed-to-fail connection look identical
        // to a healthy one in the physical-device trace that led to this
        // fix.
        newTask.resume()

        return AsyncThrowingStream { continuation in
            let pumpTask = Task { [weak self] in
                await self?.pump(newTask, into: continuation)
            }
            continuation.onTermination = { _ in
                pumpTask.cancel()
            }
        }
    }

    func sendPCM(_ data: Data) async throws {
        guard let task else { throw RealtimeTranscriptionSocketError.notConnected }
        try await task.send(.data(data))
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Reads inbound frames until the task ends (error, cancellation, or
    /// the server closing the connection). A single malformed frame is
    /// reported as a `.providerError` event, not a stream-ending
    /// throw — see `RealtimeTranscriptionEvent.decode`'s doc comment; one
    /// garbled frame shouldn't tear down an otherwise-healthy connection.
    private func pump(
        _ task: URLSessionWebSocketTask,
        into continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.Continuation
    ) async {
        // `task.receive()` succeeding for the first time is the earliest
        // point this class can honestly say the WebSocket upgrade
        // actually completed — `URLSessionWebSocketTask` gives no other
        // async-friendly signal that fires exactly on a successful
        // handshake (see `connect()`'s own doc comment for why logging
        // this any earlier, e.g. right after `resume()`, was the bug).
        // If the handshake failed (a 401, or anything else that isn't a
        // 101 Switching Protocols response), THIS first `receive()` call
        // throws instead, landing in the `catch` below with this flag
        // still `false` — genuinely confirming the negative case too.
        var hasConfirmedHandshake = false
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
                if !hasConfirmedHandshake {
                    hasConfirmedHandshake = true
                    DiagnosticTrace.log("WS_HANDSHAKE_CONFIRMED", "the WebSocket upgrade actually completed")
                    DiagnosticTrace.log("LIVE_START_SOCKET_HANDSHAKE_OK", "")
                }
            } catch {
                // TEMPORARY — remove once root-caused. `closeCode`/
                // `closeReason` are only populated once the task has
                // actually finished closing, which is exactly the state
                // `receive()` throwing puts it in.
                let nsError = error as NSError
                DiagnosticTrace.log(
                    "8B_TRACE",
                    "WS_CLOSED handshakeConfirmed=\(hasConfirmedHandshake) code=\(task.closeCode.rawValue) reason=\(task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil") error domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
                )
                if !hasConfirmedHandshake {
                    // This is a startup-time failure specifically (the
                    // handshake never succeeded even once) — a MID-
                    // session drop after a confirmed handshake is a
                    // separate, already-covered reconnect concern (see
                    // `OpenAIRealtimeTranscriber`'s bounded retry loop),
                    // not a `LIVE_START_*` stage.
                    DiagnosticTrace.log("LIVE_START_SOCKET_HANDSHAKE_FAILED", "errorType=\(type(of: error)) errorMessage=\(error)")
                }
                continuation.finish(throwing: error)
                return
            }

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { continue }
                do {
                    let decoded = try RealtimeTranscriptionEvent.decode(from: data)
                    DiagnosticTrace.log("8B_TRACE", "IOS_DECODE event=\(decoded.caseName)")
                    continuation.yield(decoded)
                } catch {
                    DiagnosticTrace.log("8B_TRACE", "ERROR malformed event from backend: \(error) raw=\(text.prefix(200))")
                    continuation.yield(.providerError("malformed event: \(error)"))
                }
            case .data:
                continue // the backend only ever sends JSON text frames — nothing to do with binary here
            @unknown default:
                continue
            }
        }
    }

    /// `URLSessionWebSocketTask` requires a `ws`/`wss` scheme;
    /// `BackendConfiguration.baseURL` (shared with every REST call) is
    /// `https` — this is the one place that scheme gets translated,
    /// rather than teaching the shared config about WebSocket at all.
    private static func webSocketURL(from url: URL?) -> URL? {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return url
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        return components.url
    }
}
