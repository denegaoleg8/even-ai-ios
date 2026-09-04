import Foundation

/// The minimal HTTP seam `OpenAIResponsesTransport` needs — narrow enough
/// that tests can substitute a fake and never touch the network, and
/// production can substitute a real `URLSession` without either side
/// knowing about the other.
protocol OpenAIProxyHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Real implementation — production would inject this. Not used by any
/// test, and not wired into `PersonalAIContainer.live` yet.
struct URLSessionOpenAIProxyHTTPClient: OpenAIProxyHTTPClient {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PersonalAIProviderOutcome.transientFailure(reason: "non-HTTP response")
        }
        return (data, http)
    }
}

/// The concrete OpenAI Responses API adapter, conforming to the existing,
/// already-shipped `PersonalAIRemoteTransport` seam — `RemotePersonalAIModelProvider`
/// needs no change to use this.
///
/// **The iOS app never possesses an OpenAI API key.** This type sends the
/// OpenAI-shaped request to `proxyURL` — the app's own thin server-side
/// proxy (see `cloudflare/personal-ai-proxy/`), not `api.openai.com`
/// directly — using `authorization` (the opaque app→proxy credential from
/// `PersonalAIRemoteAuthorizing`, a completely different trust domain from
/// the OpenAI key the proxy alone holds). The proxy attaches the real
/// OpenAI key server-side and forwards; this adapter only ever sees the
/// proxy's relayed response.
struct OpenAIResponsesTransport: PersonalAIRemoteTransport {
    let proxyURL: URL
    /// Configurable, never hardcoded into `Core/Domain` — see
    /// `OpenAIResponsesMapper.request(from:model:)`. Recommended
    /// development default: `"gpt-5.4-mini"`.
    let model: String
    let httpClient: any OpenAIProxyHTTPClient

    init(
        proxyURL: URL,
        model: String = "gpt-5.4-mini",
        httpClient: any OpenAIProxyHTTPClient = URLSessionOpenAIProxyHTTPClient()
    ) {
        self.proxyURL = proxyURL
        self.model = model
        self.httpClient = httpClient
    }

    func generate(_ request: PersonalAIRemoteRequest, authorization: String) async throws -> PersonalAIRemoteResponse {
        let dto = OpenAIResponsesMapper.request(from: request, model: model)

        var urlRequest = URLRequest(url: proxyURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The app→proxy credential only — never an OpenAI key. See the
        // type doc comment: two separate trust domains.
        urlRequest.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(dto)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await httpClient.send(urlRequest)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // `URLSession`'s async APIs can surface Task cancellation as
            // `URLError(.cancelled)` rather than stdlib `CancellationError`
            // — translate it here, at the one place that knows about
            // `URLError`, so `RemotePersonalAIModelProvider`'s generic
            // `catch is CancellationError` still catches it and the router
            // never turns a cancellation into a "successful" fallback.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PersonalAIProviderOutcome.transientFailure(reason: "network error")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw PersonalAIProviderOutcome.unavailable(reason: "app-proxy authorization rejected")
        case 408:
            throw PersonalAIProviderOutcome.transientFailure(reason: "proxy timeout")
        case 429:
            throw PersonalAIProviderOutcome.transientFailure(reason: "rate limited")
        case 500..<600:
            throw PersonalAIProviderOutcome.transientFailure(reason: "proxy/upstream server error")
        default:
            throw PersonalAIProviderOutcome.hardFailure(reason: "unexpected proxy status \(http.statusCode)")
        }

        let responseDTO: OpenAIResponsesResponseDTO
        do {
            responseDTO = try JSONDecoder().decode(OpenAIResponsesResponseDTO.self, from: data)
        } catch {
            throw PersonalAIProviderOutcome.hardFailure(reason: "malformed response")
        }
        return try OpenAIResponsesMapper.response(from: responseDTO)
    }
}
