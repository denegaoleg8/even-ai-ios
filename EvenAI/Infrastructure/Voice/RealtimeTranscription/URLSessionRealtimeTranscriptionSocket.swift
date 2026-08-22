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

    func connect() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        var request = await apiClient.makeWebSocketRequest(path: Self.path)
        request.url = Self.webSocketURL(from: request.url) ?? request.url
        let newTask = urlSession.webSocketTask(with: request)
        task = newTask
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
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { continue }
                do {
                    continuation.yield(try RealtimeTranscriptionEvent.decode(from: data))
                } catch {
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
