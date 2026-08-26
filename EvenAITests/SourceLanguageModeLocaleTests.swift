import Testing
import Foundation
@testable import EvenAI

/// Locks in the exact on-device `SFSpeechRecognizer` locale each explicit
/// `SourceLanguageMode` resolves to — the local-first architecture pass's
/// answer to "which locale for EN/DE/PL" (§4/§18 items 6-8). `en-US` (not
/// bare `en`) because `SFSpeechRecognizer(locale:)` requires a real,
/// region-qualified `Locale` identifier.
@Suite("SourceLanguageMode on-device locale mapping")
struct SourceLanguageModeLocaleTests {
    @Test("explicit EN resolves to en-US")
    func englishLocale() {
        #expect(SourceLanguageMode.en.onDeviceLocaleIdentifier == "en-US")
    }

    @Test("explicit DE resolves to de-DE")
    func germanLocale() {
        #expect(SourceLanguageMode.de.onDeviceLocaleIdentifier == "de-DE")
    }

    @Test("explicit PL resolves to pl-PL")
    func polishLocale() {
        #expect(SourceLanguageMode.pl.onDeviceLocaleIdentifier == "pl-PL")
    }

    @Test("Auto has no fixed on-device locale of its own — resolved separately by the caller")
    func autoHasNoFixedLocale() {
        #expect(SourceLanguageMode.auto.onDeviceLocaleIdentifier == nil)
    }
}
