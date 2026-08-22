import Foundation

/// Provider-neutral event model for the realtime-transcription WebSocket
/// protocol between this app and our own backend
/// (`src/realtimeTranscription/protocol.js`) — mirrors that file's six
/// event `type`s exactly. Nothing here names OpenAI (or any other
/// vendor): the backend is what decides which STT provider actually
/// produced these, and could change without this app ever knowing.
enum RealtimeTranscriptionEvent: Equatable, Sendable {
    case sessionStarted
    case partialTranscript(String)
    case finalTranscript(String)
    /// Reported separately from a transcript event, matching the
    /// backend's own `language_info` frame — see
    /// `OpenAIRealtimeTranscriber`'s doc comment on why this is captured
    /// but not currently surfaced through `ContinuousTranscribing`
    /// (Ukrainian-vs-foreign filtering stays entirely in
    /// `LiveTranslationService`, unchanged).
    case languageInfo([String])
    case providerError(String)
    case closed(reason: String?)
}

enum RealtimeTranscriptionEventDecodingError: Error, Equatable, Sendable {
    case malformedJSON
    case unknownType(String)
    case missingField(String)
}

extension RealtimeTranscriptionEvent {
    /// Parses one inbound WS text frame from the backend. Every failure
    /// mode is a thrown, typed error — a malformed frame is never
    /// silently dropped or garbled into some other event; the caller
    /// (`URLSessionRealtimeTranscriptionSocket`) decides what a thrown
    /// error here means for the connection (see its doc comment — not a
    /// fatal error for the whole session by default).
    static func decode(from data: Data) throws -> RealtimeTranscriptionEvent {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any],
            let type = object["type"] as? String
        else {
            throw RealtimeTranscriptionEventDecodingError.malformedJSON
        }

        switch type {
        case "session_started":
            return .sessionStarted

        case "partial_transcript":
            guard let text = object["text"] as? String else {
                throw RealtimeTranscriptionEventDecodingError.missingField("text")
            }
            return .partialTranscript(text)

        case "final_transcript":
            guard let text = object["text"] as? String else {
                throw RealtimeTranscriptionEventDecodingError.missingField("text")
            }
            return .finalTranscript(text)

        case "language_info":
            guard let languages = object["languages"] as? [String] else {
                throw RealtimeTranscriptionEventDecodingError.missingField("languages")
            }
            return .languageInfo(languages)

        case "error":
            guard let message = object["message"] as? String else {
                throw RealtimeTranscriptionEventDecodingError.missingField("message")
            }
            return .providerError(message)

        case "closed":
            return .closed(reason: object["reason"] as? String)

        default:
            throw RealtimeTranscriptionEventDecodingError.unknownType(type)
        }
    }
}
