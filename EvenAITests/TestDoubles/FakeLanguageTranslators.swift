import Foundation
@testable import EvenAI

/// Scriptable fake: maps each expected input text to a fixed detected
/// language code (or `nil` for "uncertain"), and translates by returning a
/// caller-supplied fixed string regardless of input — a real translation
/// isn't needed to exercise `LiveTranslationViewModel`'s decision logic.
/// An input text with no entry in `languageCodes` is treated as
/// undetectable (`nil`), matching `LanguageTranslating`'s "uncertain ⇒ do
/// nothing" contract.
actor ScriptedLanguageTranslator: LanguageTranslating {
    private let languageCodes: [String: String?]
    private let translation: String

    init(languageCodes: [String: String?], translation: String = "translated") {
        self.languageCodes = languageCodes
        self.translation = translation
    }

    func detectedLanguageCode(for text: String) async -> String? {
        languageCodes[text] ?? nil
    }

    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String {
        translation
    }
}
