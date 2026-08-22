import Foundation

/// One turn in the shared EvenAI agent conversation — the single unit
/// both iPhone Chat and the G2 Live Agent eventually read the same
/// timeline through (see `AgentContextSession`). Deliberately independent
/// of Speech/Azure/OpenAI/G2/SwiftUI: this is pure domain data, produced
/// by whatever STT/translation/agent implementation is wired in later
/// and consumed by whatever presentation layer (Chat UI, a future G2
/// Presentation Layer) needs it — nothing in this file imports anything
/// beyond `Foundation`.
///
/// Not a replacement for `Message`/`Chat`, and not extended from either:
/// those model Chat's own request/response bubbles (`role`, `status`)
/// and are left exactly as they are. A `ConversationTurn` models a
/// richer shared-agent moment (original text, detected language,
/// Ukrainian translation, suggested replies) that neither existing type
/// has any concept of — extending `Message` to carry these fields was
/// considered and rejected, since it would ripple into every existing
/// `MessageDTO`/persistence/`ChatMessageSender` code path that has no
/// notion of them, breaking "Chat must continue working unchanged."
struct ConversationTurn: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var timestamp: Date
    var originalText: String
    /// `nil` when detection hasn't run or was inconclusive — never a
    /// placeholder string like `"unknown"`, so callers can distinguish
    /// "no detection attempted/succeeded" from a real value.
    var detectedLanguage: String?
    /// `nil` whenever there is no Ukrainian translation to show — most
    /// notably when `detectedLanguage` is Ukrainian itself. This type
    /// does not enforce that rule on its plain initializer — it only
    /// represents whatever the caller decided; `liveConversationTurn(...)`
    /// below is the constructor that actually enforces it.
    var ukrainianTranslation: String?
    var suggestedReplies: [SuggestedReply]
    var source: TurnSource
    var confidence: Double?
    /// Deliberately `[String: String]`, not `[String: Any]` — keeps this
    /// type `Equatable`/`Codable`/`Sendable` without a type-erasure
    /// workaround, which is what "pure/testable domain code" actually
    /// requires in practice.
    var metadata: [String: String]?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        originalText: String,
        detectedLanguage: String? = nil,
        ukrainianTranslation: String? = nil,
        suggestedReplies: [SuggestedReply] = [],
        source: TurnSource,
        confidence: Double? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalText = originalText
        self.detectedLanguage = detectedLanguage
        self.ukrainianTranslation = ukrainianTranslation
        self.suggestedReplies = suggestedReplies
        self.source = source
        self.confidence = confidence
        self.metadata = metadata
    }
}

extension ConversationTurn {
    static let ukrainianLanguageCode = "uk"

    /// Whether `languageCode` is Ukrainian — tolerant of a bare `"uk"` or
    /// a full locale like `"uk-UA"`/`"UK-ua"`. The one place this
    /// comparison is implemented, so every consumer (this file's own
    /// `liveConversationTurn(...)` below, and later the G2 Presentation
    /// Layer and the live pipeline) agrees on what "Ukrainian" means.
    /// Mirrors `LiveTranslationService`'s existing equivalent check —
    /// this is a new, independent helper for future turn-construction
    /// call sites, not a change to that service.
    static func isUkrainian(languageCode: String?) -> Bool {
        guard let languageCode else { return false }
        return languageCode.split(separator: "-").first?.lowercased() == ukrainianLanguageCode
    }

    /// Convenience constructor for a live-conversation turn that enforces
    /// the "Ukrainian speech is never translated" product rule at the
    /// model layer: `ukrainianTranslation` is forced to `nil` whenever
    /// `detectedLanguage` is Ukrainian, regardless of what the caller
    /// passed in — so this invariant can't be silently violated by a
    /// future call site that forgets to check it itself.
    static func liveConversationTurn(
        id: UUID = UUID(),
        timestamp: Date = .now,
        originalText: String,
        detectedLanguage: String?,
        ukrainianTranslation: String?,
        suggestedReplies: [SuggestedReply] = [],
        confidence: Double? = nil,
        metadata: [String: String]? = nil
    ) -> ConversationTurn {
        ConversationTurn(
            id: id,
            timestamp: timestamp,
            originalText: originalText,
            detectedLanguage: detectedLanguage,
            ukrainianTranslation: isUkrainian(languageCode: detectedLanguage) ? nil : ukrainianTranslation,
            suggestedReplies: suggestedReplies,
            source: .liveConversation,
            confidence: confidence,
            metadata: metadata
        )
    }
}
