import Testing
import Foundation
@testable import EvenAI

/// Milestone 7: `NetworkSuggestedReplyGenerator`'s own contract — request
/// shape and response parsing — entirely independent of
/// `LiveTranslationServiceSuggestedRepliesTests`, which already covers the
/// generic `SuggestedReplyGenerating` integration contract via
/// `FakeSuggestedReplyGenerator` and stays unchanged. No real network call
/// is made anywhere here — `StubURLProtocol` intercepts every request,
/// same mechanism `NetworkChatServiceTests` already relies on.
///
/// `.serialized`: shares `StubURLProtocol`'s process-global state with
/// `NetworkChatServiceTests`/`AuthenticatedAPIClientTests` — see those
/// suites' notes.
@Suite("NetworkSuggestedReplyGenerator", .serialized)
struct NetworkSuggestedReplyGeneratorTests {
    private func makeGenerator() -> (NetworkSuggestedReplyGenerator, AuthenticatedAPIClient) {
        StubURLProtocol.reset()
        let client = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: InMemoryAuthTokenStore()
        )
        return (NetworkSuggestedReplyGenerator(apiClient: client), client)
    }

    private static func jsonResponse(_ status: Int, _ object: [String: Any]) -> StubURLProtocol.StubResponse {
        StubURLProtocol.StubResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private static func replyJSON(_ original: String, _ ukrainian: String, ordering: Int?) -> [String: Any] {
        var object: [String: Any] = ["originalLanguageText": original, "ukrainianText": ukrainian]
        if let ordering { object["ordering"] = ordering }
        return object
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try Self.bodyData(from: request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `URLSession` converts a `Data` body set via `.httpBody` into an
    /// `InputStream` (`.httpBodyStream`) before handing the request to a
    /// custom `URLProtocol` — `request.httpBody` is `nil` by the time
    /// `StubURLProtocol.handler` sees it, confirmed empirically (not
    /// documented behavior worth trusting blindly). Reading the stream
    /// manually is the only way to recover what `AuthenticatedAPIClient`
    /// actually sent.
    private static func bodyData(from request: URLRequest) throws -> Data {
        guard let stream = request.httpBodyStream else {
            Issue.record("request has neither httpBody nor httpBodyStream")
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }

    // MARK: - Request shape

    @Test("sends the current turn's original text, detected language, and Ukrainian translation")
    func sendsCurrentTurn() async throws {
        let (generator, _) = makeGenerator()
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Добрий день"
        )

        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["replies": []]) }

        _ = try await generator.generateReplies(for: turn, context: SuggestedReplyContext())

        let request = try #require(StubURLProtocol.recordedRequests().last)
        #expect(request.url?.path.hasSuffix("/suggested-replies") == true)
        let body = try Self.requestBody(request)
        let sentTurn = try #require(body["turn"] as? [String: Any])
        #expect(sentTurn["originalText"] as? String == "Guten Tag")
        #expect(sentTurn["detectedLanguage"] as? String == "de-DE")
        #expect(sentTurn["ukrainianTranslation"] as? String == "Добрий день")
    }

    @Test("sends recent turns oldest-first and shared context items")
    func sendsRecentTurnsAndContextItems() async throws {
        let (generator, _) = makeGenerator()
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Добрий день"
        )
        let priorTurn = ConversationTurn.liveConversationTurn(
            originalText: "earlier phrase",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "раніша фраза"
        )
        let contextItem = ContextItem(kind: .note, text: "Business meeting tomorrow.")

        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["replies": []]) }

        _ = try await generator.generateReplies(
            for: turn,
            context: SuggestedReplyContext(recentTurns: [priorTurn], contextItems: [contextItem])
        )

        let body = try Self.requestBody(try #require(StubURLProtocol.recordedRequests().last))
        let recentTurns = try #require(body["recentTurns"] as? [[String: Any]])
        #expect(recentTurns.count == 1)
        #expect(recentTurns.first?["originalText"] as? String == "earlier phrase")
        let contextItems = try #require(body["contextItems"] as? [[String: Any]])
        #expect(contextItems.count == 1)
        #expect(contextItems.first?["text"] as? String == "Business meeting tomorrow.")
        #expect(contextItems.first?["kind"] as? String == "note")
    }

    @Test("caps recent turns and context items sent to the most recent entries")
    func capsHistorySent() async throws {
        let (generator, _) = makeGenerator()
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag", detectedLanguage: "de-DE", ukrainianTranslation: "Добрий день"
        )
        let manyTurns = (0..<15).map { index in
            ConversationTurn.liveConversationTurn(
                originalText: "turn \(index)", detectedLanguage: "de-DE", ukrainianTranslation: "переклад \(index)"
            )
        }
        let manyContextItems = (0..<25).map { ContextItem(kind: .note, text: "note \($0)") }

        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["replies": []]) }

        _ = try await generator.generateReplies(
            for: turn,
            context: SuggestedReplyContext(recentTurns: manyTurns, contextItems: manyContextItems)
        )

        let body = try Self.requestBody(try #require(StubURLProtocol.recordedRequests().last))
        let recentTurns = try #require(body["recentTurns"] as? [[String: Any]])
        let contextItems = try #require(body["contextItems"] as? [[String: Any]])
        // Bounded, and the most *recent* entries (highest indices) are the
        // ones kept — not an arbitrary/oldest slice.
        #expect(recentTurns.count == 10)
        #expect(recentTurns.first?["originalText"] as? String == "turn 5")
        #expect(recentTurns.last?["originalText"] as? String == "turn 14")
        #expect(contextItems.count == 20)
        #expect(contextItems.first?["text"] as? String == "note 5")
    }

    // MARK: - Response parsing

    @Test("decodes exactly 3 replies from the response, preserving text and explicit ordering")
    func decodesThreeReplies() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(200, [
                "replies": [
                    Self.replyJSON("Sure, that works.", "Так, підходить.", ordering: 0),
                    Self.replyJSON("Could we do Thursday?", "Можемо у четвер?", ordering: 1),
                    Self.replyJSON("Let me check.", "Дай перевірю.", ordering: 2),
                ],
            ])
        }

        let replies = try await generator.generateReplies(
            for: .liveConversationTurn(originalText: "Guten Tag", detectedLanguage: "de-DE", ukrainianTranslation: "Добрий день"),
            context: SuggestedReplyContext()
        )

        #expect(replies.count == 3)
        #expect(replies.map(\.originalLanguageText) == ["Sure, that works.", "Could we do Thursday?", "Let me check."])
        #expect(replies.map(\.ukrainianText) == ["Так, підходить.", "Можемо у четвер?", "Дай перевірю."])
        #expect(replies.map(\.ordering) == [0, 1, 2])
    }

    @Test("defaults a reply's ordering to its array position when the backend omits it")
    func defaultsOrderingToArrayPosition() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(200, [
                "replies": [
                    Self.replyJSON("First", "Перший", ordering: nil),
                    Self.replyJSON("Second", "Другий", ordering: nil),
                ],
            ])
        }

        let replies = try await generator.generateReplies(
            for: .liveConversationTurn(originalText: "Hi", detectedLanguage: "en", ukrainianTranslation: "Привіт"),
            context: SuggestedReplyContext()
        )

        #expect(replies.map(\.ordering) == [0, 1])
    }

    @Test("an empty replies array decodes to no suggested replies, not an error")
    func emptyRepliesArrayDecodesCleanly() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["replies": []]) }

        let replies = try await generator.generateReplies(
            for: .liveConversationTurn(originalText: "Hi", detectedLanguage: "en", ukrainianTranslation: "Привіт"),
            context: SuggestedReplyContext()
        )

        #expect(replies.isEmpty)
    }

    // MARK: - Failure — never crashes, always throws

    @Test("a non-2xx HTTP response throws rather than returning fabricated replies")
    func httpErrorThrows() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(502, ["error": ["code": "UPSTREAM_LLM_ERROR", "message": "boom"]])
        }

        await #expect(throws: AuthenticatedAPIClientError.self) {
            _ = try await generator.generateReplies(
                for: .liveConversationTurn(originalText: "Hi", detectedLanguage: "en", ukrainianTranslation: "Привіт"),
                context: SuggestedReplyContext()
            )
        }
    }

    @Test("a malformed response body (missing replies field) throws rather than crashing")
    func malformedResponseThrows() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["unexpected": "shape"]) }

        await #expect(throws: (any Error).self) {
            _ = try await generator.generateReplies(
                for: .liveConversationTurn(originalText: "Hi", detectedLanguage: "en", ukrainianTranslation: "Привіт"),
                context: SuggestedReplyContext()
            )
        }
    }

    // MARK: - End-to-end through LiveTranslationService (no real network)

    @MainActor
    @Test("wired into LiveTranslationService, a stubbed backend response becomes the turn's suggested replies")
    func integratesWithLiveTranslationService() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(200, [
                "replies": [Self.replyJSON("Sure", "Так", ordering: 0)],
            ])
        }
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(100))

        let turn = try #require(store.session.latestTurn)
        #expect(turn.ukrainianTranslation == "Добрий день")
        #expect(turn.suggestedReplies.map(\.originalLanguageText) == ["Sure"])
    }

    @MainActor
    @Test("wired into LiveTranslationService, a backend failure leaves the translation turn valid with empty replies")
    func integratesWithLiveTranslationServiceOnFailure() async throws {
        let (generator, _) = makeGenerator()
        StubURLProtocol.handler = { _ in Self.jsonResponse(502, ["error": ["code": "UPSTREAM_LLM_ERROR", "message": "boom"]]) }
        let store = AgentContextStore()
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(100))

        // Never crashes, and the translation itself is still there and
        // still on G2 — a reply-generation failure never hides it.
        #expect(await spy.displayedPageSets == [["Добрий день"]])
        let turn = try #require(store.session.latestTurn)
        #expect(turn.ukrainianTranslation == "Добрий день")
        #expect(turn.suggestedReplies.isEmpty)
    }
}
