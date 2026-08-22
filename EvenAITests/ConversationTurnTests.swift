import Foundation
import Testing
@testable import EvenAI

/// Pure domain-model tests — no Speech/Azure/OpenAI/G2/SwiftUI involved,
/// matching `ConversationTurn`'s own independence requirement.
@Suite("ConversationTurn")
struct ConversationTurnTests {
    @Test("creating a turn captures every field exactly as given")
    func createsTurn() {
        let reply = SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0)
        let turn = ConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Добрий день",
            suggestedReplies: [reply],
            source: .liveConversation,
            confidence: 0.9,
            metadata: ["provider": "azure"]
        )

        #expect(turn.originalText == "Guten Tag")
        #expect(turn.detectedLanguage == "de-DE")
        #expect(turn.ukrainianTranslation == "Добрий день")
        #expect(turn.suggestedReplies == [reply])
        #expect(turn.source == .liveConversation)
        #expect(turn.confidence == 0.9)
        #expect(turn.metadata == ["provider": "azure"])
    }

    @Test("a turn defaults to no replies, no detected language, no translation, no confidence, no metadata")
    func defaults() {
        let turn = ConversationTurn(originalText: "hello", source: .phoneChat)
        #expect(turn.suggestedReplies.isEmpty)
        #expect(turn.detectedLanguage == nil)
        #expect(turn.ukrainianTranslation == nil)
        #expect(turn.confidence == nil)
        #expect(turn.metadata == nil)
    }

    @Test("suggested replies preserve their own ordering value independent of array position")
    func suggestedReplyOrdering() {
        let first = SuggestedReply(originalLanguageText: "Sure, no problem.", ukrainianText: "Так, без проблем.", ordering: 0)
        let second = SuggestedReply(originalLanguageText: "Thursday works for me.", ukrainianText: "Четвер мені підходить.", ordering: 1)
        let third = SuggestedReply(originalLanguageText: "Let me check.", ukrainianText: "Дай перевірю.", ordering: 2)

        // Constructed out of order deliberately, to prove `ordering`
        // (not array index) is what's authoritative.
        let turn = ConversationTurn(
            originalText: "Перенесемо зустріч на четвер?",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Can we move the meeting to Thursday?",
            suggestedReplies: [third, first, second],
            source: .liveConversation
        )

        #expect(turn.suggestedReplies.map(\.ordering) == [2, 0, 1])
        #expect(turn.suggestedReplies.sorted { $0.ordering < $1.ordering }.map(\.originalLanguageText) == [
            "Sure, no problem.", "Thursday works for me.", "Let me check.",
        ])
    }

    @Test("isUkrainian recognizes a bare code and a full locale, case-insensitively")
    func isUkrainianRecognizesBareAndLocaleForms() {
        #expect(ConversationTurn.isUkrainian(languageCode: "uk"))
        #expect(ConversationTurn.isUkrainian(languageCode: "uk-UA"))
        #expect(ConversationTurn.isUkrainian(languageCode: "UK-ua"))
        #expect(!ConversationTurn.isUkrainian(languageCode: "en-US"))
        #expect(!ConversationTurn.isUkrainian(languageCode: nil))
    }

    @Test("liveConversationTurn ignores a supplied Ukrainian translation when the detected language is Ukrainian")
    func ignoresUkrainianTranslationWhenSourceIsUkrainian() {
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "Привіт, як справи?",
            detectedLanguage: "uk-UA",
            ukrainianTranslation: "Привіт, як справи?" // even if a caller mistakenly supplies one
        )
        #expect(turn.ukrainianTranslation == nil)
        #expect(turn.detectedLanguage == "uk-UA")
        #expect(turn.source == .liveConversation)
    }

    @Test("liveConversationTurn keeps a real translation for a non-Ukrainian source language")
    func keepsTranslationForForeignLanguage() {
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Добрий день"
        )
        #expect(turn.ukrainianTranslation == "Добрий день")
        #expect(turn.detectedLanguage == "de-DE")
    }

    @Test("liveConversationTurn ignores a nil detected language the same as a non-Ukrainian one")
    func keepsTranslationWhenLanguageUnknown() {
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "???",
            detectedLanguage: nil,
            ukrainianTranslation: "some translation"
        )
        #expect(turn.ukrainianTranslation == "some translation")
    }
}
