import Foundation

/// Abstraction over per-phrase language identification and translation
/// into Ukrainian. Deliberately generic over the detected source language
/// code (a BCP-47 identifier, e.g. `"en"`, `"uk"`) rather than
/// English-specific, so later milestones can recognize/translate
/// additional source languages without changing this protocol.
/// `AppleLanguageTranslator` is the concrete implementation
/// (`NaturalLanguage` + `Translation`, both first-party — no third-party
/// dependency, no backend call).
protocol LanguageTranslating: Sendable {
    /// Identifies the dominant language of `text`. Returns `nil` when
    /// detection is too uncertain to act on — callers must treat that as
    /// "do nothing", never as a fallback language, per the product
    /// requirement that uncertain detection produces no display output.
    func detectedLanguageCode(for text: String) async -> String?

    /// Translates `text`, already known to be in `sourceLanguageCode`,
    /// into Ukrainian.
    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String
}
