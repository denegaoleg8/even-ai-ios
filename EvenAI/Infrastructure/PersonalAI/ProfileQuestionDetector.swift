import Foundation

/// Which stored self-fact a "what is my …?" question is asking about.
enum ProfileAspect: String, CaseIterable, Sendable {
    case name, location, occupation, language
}

/// Deterministic, multilingual (uk / en / de / pl) detector for *"the user is
/// asking me to recall a stored fact about themselves"* — e.g. "What is my
/// name?", "Де я живу?", "Was mache ich beruflich?".
///
/// Centralised so two consumers agree:
///  - `MemoryRetriever` — on a profile question, `.profile` records are let
///    past the generic topical-connection gate for that turn (a Personal AI
///    must be able to answer "what is my name?" with **no semantic model**,
///    even when the fact was stored in another language);
///  - `HeuristicPersonalAIModelProvider` — answers directly from the fact
///    instead of a generic template.
///
/// It is **not** an "is this about the user" classifier for arbitrary text —
/// it only fires on interrogative phrasings that map to a known aspect, so it
/// never turns profile memory into unconditional prompt injection.
struct ProfileQuestionDetector: Sendable {

    init() {}

    /// The profile aspects the message asks about. Empty ⇒ not a profile
    /// question ⇒ callers change nothing.
    func aspects(in message: String) -> Set<ProfileAspect> {
        let l = CommandInterpreter.normalize(message.lowercased())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, Self.looksInterrogative(l) else { return [] }
        var found: Set<ProfileAspect> = []
        for (aspect, phrases) in Self.questionPhrases where phrases.contains(where: l.contains) {
            found.insert(aspect)
        }
        return found
    }

    // MARK: - Storage-side markers (for the provider to locate the answering fact)

    /// Phrases that indicate a *stored* record carries this aspect's value.
    static func storageMarkers(for aspect: ProfileAspect) -> [String] {
        switch aspect {
        case .name:
            return ["my name is", "мене звати", "мене звуть", "мене звали", "моє імʼя", "моє ім'я",
                    "mein name ist", "ich heiße", "ich heisse", "nazywam się", "nazywam sie",
                    "mam na imię", "mam na imie", "moje imię to", "moje imie to"]
        case .location:
            return ["i live in", "i'm based in", "im based in", "i am based in", "i reside in",
                    "я живу в", "я живу у", "я мешкаю в", "я мешкаю у",
                    "ich wohne in", "ich lebe in",
                    "mieszkam w", "mieszkam we", "żyję w", "zyje w"]
        case .occupation:
            return ["i work as", "i'm a ", "im a ", "i am a ", "my job is", "my role is",
                    "i work at", "i work for", "my occupation is", "my profession is",
                    "я працюю", "моя посада", "моя роль", "я обіймаю посаду", "я займаюся", "я займаюсь",
                    "ich arbeite als", "ich bin ", "ich arbeite bei", "mein beruf ist", "meine rolle ist",
                    "pracuję jako", "pracuje jako", "pracuję w", "pracuje w", "mój zawód to", "moja rola to",
                    "moje stanowisko to", "zajmuję się", "zajmuje sie"]
        case .language:
            return ["i speak ", "languages i speak", "я розмовляю", "я говорю", "володію мовами", "знаю мови",
                    "ich spreche", "mówię ", "mowie ", "znam języki", "znam jezyki", "posługuję się"]
        }
    }

    // MARK: - Question-side phrases

    private static func looksInterrogative(_ l: String) -> Bool {
        if l.hasSuffix("?") { return true }
        let starters = [
            "what ", "what's", "whats ", "which ", "where ", "who ", "how ", "do you ", "does ", "tell me ",
            "як ", "яка ", "який ", "яке ", "якими ", "які ", "де ", "хто ", "чим ", "в якій ", "в якому ",
            "wie ", "was ", "wo ", "welche ", "welcher ", "wer ",
            "jak ", "jaka ", "jaki ", "jakie ", "jakim ", "jakimi ", "gdzie ", "kim ", "czym ", "w jakiej ", "w jakim ",
        ]
        return starters.contains { l.hasPrefix($0) }
    }

    private static let questionPhrases: [(ProfileAspect, [String])] = [
        (.name, [
            "my name", "remember my name", "who am i",
            "як мене звати", "як мене звуть", "як моє імʼя", "як моє ім'я", "моє імʼя", "моє ім'я", "хто я такий", "хто я",
            "wie heiße ich", "wie heisse ich", "mein name", "wer bin ich",
            "jak mam na imię", "jak mam na imie", "jak się nazywam", "jak sie nazywam", "moje imię", "moje imie", "kim jestem",
        ]),
        (.location, [
            "where do i live", "where am i based", "where do i reside", "which city do i live", "what city do i live",
            "де я живу", "де я мешкаю", "в якому місті я живу", "в якому місті я мешкаю",
            "wo wohne ich", "wo lebe ich", "in welcher stadt wohne ich",
            "gdzie mieszkam", "w jakim mieście mieszkam", "gdzie żyję", "gdzie zyje",
        ]),
        (.occupation, [
            "what do i do for work", "what do i do for a living", "what is my job", "what's my job", "whats my job",
            "what is my role", "what's my role", "what is my occupation", "what is my profession",
            "where do i work", "what company do i work for", "which company do i work for", "who do i work for",
            "ким я працюю", "де я працюю", "яка моя посада", "яка моя роль", "в якій компанії я працюю",
            "чим я займаюся", "чим я займаюсь", "хто я за професією",
            "was mache ich beruflich", "was bin ich von beruf", "wo arbeite ich", "was ist mein beruf",
            "welche firma", "für welche firma arbeite ich", "was ist meine rolle", "was ist meine position",
            "czym się zajmuję", "czym sie zajmuje", "gdzie pracuję", "gdzie pracuje", "jaki jest mój zawód",
            "jaka jest moja rola", "w jakiej firmie pracuję", "w jakiej firmie pracuje",
        ]),
        (.language, [
            "what languages do i speak", "which languages do i speak", "what language do i speak",
            "якими мовами я розмовляю", "яку мову я знаю", "які мови я знаю", "якими мовами я володію",
            "welche sprachen spreche ich",
            "jakimi językami mówię", "jakimi jezykami mowie", "jakie języki znam", "jakie jezyki znam",
        ]),
    ]
}
