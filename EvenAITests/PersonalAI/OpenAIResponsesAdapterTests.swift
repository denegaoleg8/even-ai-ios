import Testing
import Foundation
@testable import EvenAI

/// Tests for the concrete OpenAI Responses API adapter
/// (`OpenAIResponsesTransport`, `OpenAIResponsesMapper`, the DTOs). No real
/// network call anywhere here — `FakeOpenAIProxyHTTPClient` only, and it
/// never touches `api.openai.com`. The iOS app never possesses an OpenAI
/// key; `authorization` throughout is a fake app→proxy token.
@Suite("Personal AI: OpenAI Responses adapter")
struct OpenAIResponsesAdapterTests {

    private func remoteRequest(contextText: String = "some rendered context", userMessage: String = "hello") -> PersonalAIRemoteRequest {
        PersonalAIRemoteRequest(contextText: contextText, recentMessages: [], userMessage: userMessage, maxOutputTokens: 500)
    }

    private func fixture(text: String) -> Data {
        let json = """
        {"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\(text)"}]}]}
        """
        return Data(json.utf8)
    }

    private let proxyURL = URL(string: "https://proxy.example.invalid/personal-ai/generate")!

    // MARK: - request mapping

    @Test("the OpenAI request DTO carries context as instructions, bounded history, and the new user turn last")
    func requestMapping() {
        let remote = PersonalAIRemoteRequest(
            contextText: "known facts block",
            recentMessages: [
                PersonalAIRemoteMessage(role: .user, text: "earlier question"),
                PersonalAIRemoteMessage(role: .assistant, text: "earlier answer")
            ],
            userMessage: "the new question",
            maxOutputTokens: 321
        )
        let dto = OpenAIResponsesMapper.request(from: remote, model: "gpt-5.4-mini")
        #expect(dto.model == "gpt-5.4-mini")
        #expect(dto.instructions == "known facts block")
        #expect(dto.max_output_tokens == 321)
        #expect(dto.input.count == 3)
        #expect(dto.input[0] == OpenAIResponsesInputItem(role: "user", content: "earlier question"))
        #expect(dto.input[1] == OpenAIResponsesInputItem(role: "assistant", content: "earlier answer"))
        #expect(dto.input[2] == OpenAIResponsesInputItem(role: "user", content: "the new question"))
    }

    @Test("empty context text becomes nil instructions, not an empty string")
    func emptyContextBecomesNilInstructions() {
        let remote = PersonalAIRemoteRequest(contextText: "", recentMessages: [], userMessage: "hi", maxOutputTokens: 500)
        let dto = OpenAIResponsesMapper.request(from: remote, model: "gpt-5.4-mini")
        #expect(dto.instructions == nil)
    }

    // MARK: - model configurable

    @Test("the configured model string reaches the request DTO, not a hardcoded default")
    func modelIsConfigurable() {
        let dto = OpenAIResponsesMapper.request(from: remoteRequest(), model: "some-other-model-id")
        #expect(dto.model == "some-other-model-id")
    }

    // MARK: - response mapping (valid)

    @Test("a valid single-text response maps to the exact output text")
    func validTextResponse() async throws {
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: fixture(text: "hello back"))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        let result = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
        #expect(result.text == "hello back")
    }

    @Test("multiple output_text parts in one message are concatenated")
    func multiplePartsConcatenated() async throws {
        let json = """
        {"output":[{"type":"message","content":[{"type":"output_text","text":"part one "},{"type":"output_text","text":"part two"}]}]}
        """
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: Data(json.utf8))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        let result = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
        #expect(result.text == "part one part two")
    }

    @Test("an unrecognized future output item type is safely ignored, not treated as an error")
    func unsupportedOutputItemIgnored() async throws {
        let json = """
        {"output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"internal, not for the user"}]},{"type":"message","content":[{"type":"output_text","text":"the real answer"}]}]}
        """
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: Data(json.utf8))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        let result = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
        #expect(result.text == "the real answer")
        #expect(result.text.contains("internal") == false)
    }

    // MARK: - response mapping (failure — never fabricate)

    @Test("empty output throws .hardFailure and never fabricates text")
    func emptyOutputThrows() async throws {
        let json = """
        {"output":[]}
        """
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: Data(json.utf8))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        await #expect(throws: PersonalAIProviderOutcome.self) {
            _ = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
        }
    }

    @Test("a response with only an error field throws .hardFailure with OpenAI's message")
    func errorFieldThrows() async throws {
        let json = """
        {"error":{"message":"the model is overloaded","type":"server_error"}}
        """
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: Data(json.utf8))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        do {
            _ = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
            Issue.record("expected a thrown error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .hardFailure(let reason) = outcome else {
                Issue.record("expected .hardFailure, got \(outcome)")
                return
            }
            #expect(reason.contains("overloaded"))
        }
    }

    @Test("malformed JSON throws .hardFailure and never fabricates text")
    func malformedJSONThrows() async throws {
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: Data("not json at all {{{".utf8))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        do {
            _ = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
            Issue.record("expected a thrown error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .hardFailure(let reason) = outcome else {
                Issue.record("expected .hardFailure, got \(outcome)")
                return
            }
            #expect(reason.contains("malformed"))
        }
    }

    // MARK: - HTTP status → provider-neutral category

    @Test("HTTP 401 maps to .unavailable")
    func http401MapsToUnavailable() async throws {
        let http = FakeOpenAIProxyHTTPClient(status: 401, body: Data())
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        do {
            _ = try await transport.generate(remoteRequest(), authorization: "bad-token")
            Issue.record("expected a thrown error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .unavailable = outcome else {
                Issue.record("expected .unavailable, got \(outcome)")
                return
            }
        }
    }

    @Test("HTTP 429 maps to .transientFailure")
    func http429MapsToTransientFailure() async throws {
        let http = FakeOpenAIProxyHTTPClient(status: 429, body: Data())
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        do {
            _ = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
            Issue.record("expected a thrown error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .transientFailure = outcome else {
                Issue.record("expected .transientFailure, got \(outcome)")
                return
            }
        }
    }

    @Test("HTTP 500 maps to .transientFailure")
    func http500MapsToTransientFailure() async throws {
        let http = FakeOpenAIProxyHTTPClient(status: 500, body: Data())
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        do {
            _ = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
            Issue.record("expected a thrown error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .transientFailure = outcome else {
                Issue.record("expected .transientFailure, got \(outcome)")
                return
            }
        }
    }

    // MARK: - cancellation

    @Test("a URLError(.cancelled) from the HTTP client becomes CancellationError, not a wrapped outcome")
    func cancellationPreserved() async throws {
        let http = FakeOpenAIProxyHTTPClient(error: URLError(.cancelled))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        await #expect(throws: CancellationError.self) {
            _ = try await transport.generate(remoteRequest(), authorization: "fake-app-token")
        }
    }

    // MARK: - authorization / key boundary

    @Test("the request carries the app token as Authorization, and no OpenAI-key-shaped value anywhere")
    func authorizationBoundary() async throws {
        let http = FakeOpenAIProxyHTTPClient(status: 200, body: fixture(text: "ok"))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: http)
        _ = try await transport.generate(remoteRequest(), authorization: "fake-app-proxy-token-not-openai")

        let sent = try #require(await http.lastRequest)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fake-app-proxy-token-not-openai")

        let bodyString = String(data: sent.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(bodyString.contains("sk-") == false)
        #expect(bodyString.localizedCaseInsensitiveContains("OPENAI_API_KEY") == false)
    }
}
