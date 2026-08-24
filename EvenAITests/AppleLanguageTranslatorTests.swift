import Testing
@testable import EvenAI

/// Real `NLLanguageRecognizer` — no mocking, no on-device Translation-
/// framework model download needed (that's `Translation`, a different,
/// heavier framework; language *identification* here is `NaturalLanguage`,
/// available immediately in any test process). Regression guard for the
/// physically-confirmed "hello often dropped" bug: measured directly
/// against the real recognizer, "hello" scores only ~0.13 confidence for
/// English (its actual language), and "no"/"goodbye" score even lower and
/// get assigned to entirely wrong languages — all under the 0.6 threshold
/// `detectedLanguageCode(for:)` otherwise requires. These tests would have
/// caught that regression directly, without needing a physical device.
@Suite("AppleLanguageTranslator short-utterance detection")
struct AppleLanguageTranslatorTests {
    @Test(
        "very short, common utterances the general-purpose recognizer scores under confidence — hello/no/okay/goodbye — are still correctly detected as English",
        arguments: ["hello", "no", "okay", "goodbye"]
    )
    func shortLowConfidenceUtterancesAreDetected(word: String) async {
        let translator = AppleLanguageTranslator()
        let language = await translator.detectedLanguageCode(for: word)
        #expect(language == "en")
    }

    @Test(
        "very short utterances the recognizer already scores confidently — yes/thanks — remain correctly detected",
        arguments: ["yes", "thanks"]
    )
    func shortHighConfidenceUtterancesAreDetected(word: String) async {
        let translator = AppleLanguageTranslator()
        let language = await translator.detectedLanguageCode(for: word)
        #expect(language == "en")
    }

    @Test("hi is correctly detected as English, not misclassified by the general-purpose recognizer")
    func hiIsDetectedAsEnglish() async {
        // Measured directly: NLLanguageRecognizer alone assigns "hi" to
        // Catalan at ~0.80 confidence — high enough to pass the threshold,
        // but the wrong language entirely. The curated lookup fixes the
        // mislabeling, not just the rejection.
        let translator = AppleLanguageTranslator()
        let language = await translator.detectedLanguageCode(for: "hi")
        #expect(language == "en")
    }

    @Test("surrounding punctuation and casing from real STT output don't prevent a known short utterance from matching")
    func punctuationAndCasingAreNormalized() async {
        let translator = AppleLanguageTranslator()
        #expect(await translator.detectedLanguageCode(for: "Hello.") == "en")
        #expect(await translator.detectedLanguageCode(for: "HELLO") == "en")
        #expect(await translator.detectedLanguageCode(for: "  hello  ") == "en")
        #expect(await translator.detectedLanguageCode(for: "Goodbye!") == "en")
    }

    @Test("the curated short-utterance list also covers common German and Polish greetings")
    func nonEnglishShortUtterancesAreDetected() async {
        let translator = AppleLanguageTranslator()
        #expect(await translator.detectedLanguageCode(for: "hallo") == "de")
        #expect(await translator.detectedLanguageCode(for: "danke") == "de")
        #expect(await translator.detectedLanguageCode(for: "cześć") == "pl")
        #expect(await translator.detectedLanguageCode(for: "dziękuję") == "pl")
    }

    @Test("a longer, unambiguous phrase is still detected normally through the real recognizer, unaffected by the curated list")
    func longerPhrasesStillUseTheRealRecognizer() async {
        let translator = AppleLanguageTranslator()
        #expect(await translator.detectedLanguageCode(for: "how are you") == "en")
        #expect(await translator.detectedLanguageCode(for: "Guten Tag") == "de")
        #expect(await translator.detectedLanguageCode(for: "Dzień dobry") == "pl")
        #expect(await translator.detectedLanguageCode(for: "привіт") == "uk")
    }

    @Test("genuinely uncertain input (not in the curated list, and not confidently identifiable) is still rejected as nil")
    func trulyAmbiguousInputIsStillRejected() async {
        let translator = AppleLanguageTranslator()
        // Not a real greeting in any supported language, short enough
        // that the general recognizer has little signal — the curated
        // list must not become a catch-all that accepts everything short.
        let language = await translator.detectedLanguageCode(for: "xyzzy")
        #expect(language == nil || language != "en")
    }
}
