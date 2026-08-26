import Foundation
@testable import EvenAI

/// Scriptable fake: maps each expected input text to a fixed detected
/// language code (or `nil` for "uncertain"), and translates by returning a
/// caller-supplied fixed string regardless of input — a real translation
/// isn't needed to exercise `AIConversationViewModel`'s decision logic.
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

/// Records every `detectedLanguageCode(for:)` call — lets a test assert
/// language detection was (or, critically, was NOT) invoked at all,
/// independent of whatever it would have returned. Also records every
/// `translateToUkrainian(_:from:)` call, including exactly which
/// `sourceLanguageCode` was passed — the pair of these is what actually
/// proves "explicit mode never runs detection AND translates using the
/// selected language, with no detector involved at all," not just one or
/// the other. `detectionResult` defaults to `nil` (total, permanent
/// detection failure) — the worst case a test can throw at explicit mode
/// to prove detection failure is structurally incapable of affecting it.
actor RecordingLanguageTranslator: LanguageTranslating {
    private(set) var detectionCallCount = 0
    private(set) var detectionCalls: [String] = []
    private(set) var translateCalls: [(text: String, languageCode: String)] = []
    private let detectionResult: String?
    private let translation: String

    init(detectionResult: String? = nil, translation: String = "translated") {
        self.detectionResult = detectionResult
        self.translation = translation
    }

    func detectedLanguageCode(for text: String) async -> String? {
        detectionCallCount += 1
        detectionCalls.append(text)
        return detectionResult
    }

    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String {
        translateCalls.append((text, sourceLanguageCode))
        return translation
    }
}

/// Detects every input as a fixed, always-foreign language; translation
/// throws only for texts named in `failingTexts` (everything else
/// succeeds with `translation`) — lets a test verify
/// `AIConversationEngine.handle(final:)`'s translation-failure path
/// (no turn appended, no display update, session stays `.listening`) for
/// one phrase while confirming a *different* phrase in the same session
/// still succeeds normally, without needing a real translator that fails
/// unconditionally.
/// `translateToUkrainian` never returns for any text named in
/// `hangingTexts` (it sleeps far longer than any test's timeout, then gets
/// cancelled once `AIConversationEngine.translateWithTimeout`'s race
/// resolves) — every other text translates normally and immediately. Lets
/// a test prove the timeout actually bounds a stuck translation call
/// instead of permanently wedging `consume(_:)`'s sequential loop, the
/// concrete failure mode behind a real physical-device hang (a
/// `TranslationSession.translate(_:)` call that could never return
/// because the system UI it needed to present was blocked by another
/// sheet — see `AIConversationEngine.translateWithTimeout`'s doc
/// comment).
actor HangingLanguageTranslator: LanguageTranslating {
    private let languageCodes: [String: String]
    private let hangingTexts: Set<String>
    private let translation: String

    init(languageCodes: [String: String], hangingTexts: Set<String>, translation: String = "translated") {
        self.languageCodes = languageCodes
        self.hangingTexts = hangingTexts
        self.translation = translation
    }

    func detectedLanguageCode(for text: String) async -> String? {
        languageCodes[text]
    }

    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String {
        guard !hangingTexts.contains(text) else {
            try await Task.sleep(for: .seconds(3600))
            return translation // unreachable in practice — the sleep above is always cancelled first
        }
        return translation
    }
}

/// Translates instantly for every text NOT listed in `delays`, and after
/// the given per-text delay for those that are — lets a test construct a
/// deterministic "turn A's translation is slower than turn B's" race
/// (turn A spoken first but finishes translating after turn B) without
/// relying on incidental scheduling timing, to exercise
/// `AIConversationEngine`'s sequence-based "a newer turn has already
/// displayed" staleness guard directly at the *translation* level (not
/// just replies).
actor DelayedLanguageTranslator: LanguageTranslating {
    private let languageCodes: [String: String]
    private let delays: [String: Duration]
    private let translations: [String: String]
    private let defaultTranslation: String

    init(
        languageCodes: [String: String],
        delays: [String: Duration] = [:],
        translations: [String: String] = [:],
        defaultTranslation: String = "translated"
    ) {
        self.languageCodes = languageCodes
        self.delays = delays
        self.translations = translations
        self.defaultTranslation = defaultTranslation
    }

    func detectedLanguageCode(for text: String) async -> String? {
        languageCodes[text]
    }

    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String {
        if let delay = delays[text] {
            try await Task.sleep(for: delay)
        }
        return translations[text] ?? defaultTranslation
    }
}

actor ThrowingLanguageTranslator: LanguageTranslating {
    struct TranslationFailure: Error, Equatable {}

    private let detectedLanguageCode: String
    private let failingTexts: Set<String>
    private let translation: String

    init(detectedLanguageCode: String = "de", failingTexts: Set<String>, translation: String = "translated") {
        self.detectedLanguageCode = detectedLanguageCode
        self.failingTexts = failingTexts
        self.translation = translation
    }

    func detectedLanguageCode(for text: String) async -> String? {
        detectedLanguageCode
    }

    func translateToUkrainian(_ text: String, from sourceLanguageCode: String) async throws -> String {
        guard !failingTexts.contains(text) else { throw TranslationFailure() }
        return translation
    }
}
