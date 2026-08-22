import Testing
import Foundation
@testable import EvenAI

/// Pure decode-level tests for `RealtimeTranscriptionEvent` — no socket,
/// no networking, exercising exactly the six wire shapes
/// `src/realtimeTranscription/protocol.js` defines, plus malformed input.
@Suite("RealtimeTranscriptionEvent decoding")
struct RealtimeTranscriptionEventTests {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("decodes session_started")
    func decodesSessionStarted() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "session_started"]))
        #expect(event == .sessionStarted)
    }

    @Test("decodes partial_transcript")
    func decodesPartial() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "partial_transcript", "text": "Guten Ta"]))
        #expect(event == .partialTranscript("Guten Ta"))
    }

    @Test("decodes final_transcript")
    func decodesFinal() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "final_transcript", "text": "Guten Tag"]))
        #expect(event == .finalTranscript("Guten Tag"))
    }

    @Test("decodes language_info")
    func decodesLanguageInfo() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "language_info", "languages": ["de", "en"]]))
        #expect(event == .languageInfo(["de", "en"]))
    }

    @Test("decodes error")
    func decodesError() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "error", "message": "boom"]))
        #expect(event == .providerError("boom"))
    }

    @Test("decodes closed with a reason")
    func decodesClosedWithReason() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "closed", "reason": "network blip"]))
        #expect(event == .closed(reason: "network blip"))
    }

    @Test("decodes closed with no reason")
    func decodesClosedWithoutReason() throws {
        let event = try RealtimeTranscriptionEvent.decode(from: json(["type": "closed"]))
        #expect(event == .closed(reason: nil))
    }

    @Test("throws on non-JSON garbage")
    func throwsOnGarbage() {
        #expect(throws: RealtimeTranscriptionEventDecodingError.malformedJSON) {
            _ = try RealtimeTranscriptionEvent.decode(from: Data("not json at all {{{".utf8))
        }
    }

    @Test("throws on JSON with no type field")
    func throwsOnMissingType() {
        #expect(throws: RealtimeTranscriptionEventDecodingError.malformedJSON) {
            _ = try RealtimeTranscriptionEvent.decode(from: json(["text": "no type here"]))
        }
    }

    @Test("throws on an unrecognized type")
    func throwsOnUnknownType() {
        #expect(throws: RealtimeTranscriptionEventDecodingError.unknownType("something_new")) {
            _ = try RealtimeTranscriptionEvent.decode(from: json(["type": "something_new"]))
        }
    }

    @Test("throws on a final_transcript missing its text field")
    func throwsOnMissingRequiredField() {
        #expect(throws: RealtimeTranscriptionEventDecodingError.missingField("text")) {
            _ = try RealtimeTranscriptionEvent.decode(from: json(["type": "final_transcript"]))
        }
    }
}
