import Foundation

/// A rule-based `SuggestedReplyGenerating` implementation that needs
/// NOTHING beyond what's already on the phone — no Apple Intelligence, no
/// `FoundationModels`, no network. Exists because Apple Intelligence is
/// genuinely unavailable on real hardware this app has to support today
/// (confirmed physically: `REPLIES_LOCAL_PROVIDER_UNAVAILABLE
/// reason=appleIntelligenceNotEnabled`) — suggested replies must not
/// simply disappear whenever that's true.
///
/// Not a language model: this classifies the latest utterance into one of
/// a small set of conversational INTENTS (greeting, a "how are you?"-style
/// well-being question, a time question, an invitation/offer, a general
/// yes/no question, a general wh-question, or a plain statement) using
/// simple keyword/pattern matching per language, then returns a
/// hand-written, context-appropriate template for that intent — each
/// template already paired with its Ukrainian meaning, matching
/// `SuggestedReply`'s own shape exactly. Deliberately favors being
/// USEFUL over being clever: "Yes, I'd love to." for an invitation beats
/// any generic filler, even though neither is truly "understanding" what
/// was said.
///
/// Supports the app's three primary source languages (EN/DE/PL) — an
/// unrecognized/`nil` `detectedLanguage` falls back to English, the same
/// default `AIConversationEngine`'s own on-device locale resolution uses
/// elsewhere (see `EvenAIApp.resolveOnDeviceLocale`).
struct LightweightLocalReplyGenerator: SuggestedReplyGenerating {
    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        let text = turn.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let language = Self.resolveLanguage(turn.detectedLanguage)
        let intent = Self.classifyIntent(text, language: language)
        return Self.templates(for: intent, language: language)
            .enumerated()
            .map { index, template in
                SuggestedReply(originalLanguageText: template.source, ukrainianText: template.ukrainian, ordering: index)
            }
    }

    // MARK: - Language resolution

    enum Language {
        case en, de, pl
    }

    /// Tolerant of a bare `"en"` or a full locale-style code like
    /// `"en-US"`/`"EN-gb"` — only the primary subtag matters here.
    static func resolveLanguage(_ code: String?) -> Language {
        guard let primary = code?.split(separator: "-").first?.lowercased() else { return .en }
        switch primary {
        case "de": return .de
        case "pl": return .pl
        default: return .en
        }
    }

    // MARK: - Intent classification

    enum Intent {
        case greeting
        case wellBeingQuestion
        case timeQuestion
        case invitation
        case yesNoQuestion
        case whQuestion
        case statement
    }

    /// Checked in priority order — the FIRST matching category wins, most
    /// specific first (a well-being question and a plain greeting can
    /// both start with "hallo", but only one is actually a question).
    static func classifyIntent(_ text: String, language: Language) -> Intent {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isQuestion = normalized.hasSuffix("?")
        let keywords = Self.keywords(for: language)

        if isQuestion, keywords.wellBeing.contains(where: normalized.contains) {
            return .wellBeingQuestion
        }
        if !isQuestion, keywords.greetings.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") || normalized.hasPrefix($0 + ",") }) {
            return .greeting
        }
        if isQuestion, keywords.timeQuestion.contains(where: normalized.contains) {
            return .timeQuestion
        }
        if isQuestion, keywords.invitation.contains(where: normalized.contains) {
            return .invitation
        }
        if isQuestion, keywords.yesNoStarters.contains(where: normalized.hasPrefix) {
            return .yesNoQuestion
        }
        if isQuestion, keywords.whStarters.contains(where: normalized.hasPrefix) {
            return .whQuestion
        }
        if isQuestion {
            // A question that matched none of the more specific patterns
            // above still deserves a yes/no-shaped reply set — closer to
            // useful than a plain statement acknowledgment would be.
            return .yesNoQuestion
        }
        return .statement
    }

    private struct LanguageKeywords {
        let greetings: [String]
        let wellBeing: [String]
        let timeQuestion: [String]
        let invitation: [String]
        let yesNoStarters: [String]
        let whStarters: [String]
    }

    private static func keywords(for language: Language) -> LanguageKeywords {
        switch language {
        case .en:
            LanguageKeywords(
                greetings: ["hello", "hi", "hey", "good morning", "good afternoon", "good evening", "morning", "evening"],
                wellBeing: ["how are you", "how're you", "how you doing", "how's it going", "how is it going"],
                timeQuestion: ["what time", "when "],
                invitation: ["do you want to", "would you like to", "want to come", "like some", "do you want", "care to join", "fancy"],
                yesNoStarters: ["do you", "does ", "did you", "are you", "is it", "is there", "can you", "could you", "would you", "will you", "have you", "shall we"],
                whStarters: ["what", "where", "why", "who", "which", "how"]
            )
        case .de:
            LanguageKeywords(
                greetings: ["hallo", "guten tag", "guten morgen", "guten abend", "servus", "moin", "hi"],
                wellBeing: ["wie geht es dir", "wie geht's", "wie geht es ihnen"],
                timeQuestion: ["wann", "um wie viel uhr", "wieviel uhr", "welche uhrzeit"],
                invitation: ["möchtest du", "willst du", "hast du lust", "kommst du mit"],
                yesNoStarters: ["bist du", "hast du", "kannst du", "könntest du", "würdest du", "wirst du", "ist es", "gibt es", "machst du", "kommst du"],
                whStarters: ["was", "wo", "warum", "wer", "welche", "wieso", "weshalb", "wie"]
            )
        case .pl:
            LanguageKeywords(
                greetings: ["cześć", "dzień dobry", "witam", "siema", "hej", "dobry wieczór"],
                wellBeing: ["jak się masz", "co słychać", "jak leci"],
                timeQuestion: ["o której", "kiedy"],
                invitation: ["czy chciałbyś", "czy chcesz", "chcesz", "masz ochotę"],
                yesNoStarters: ["czy "],
                whStarters: ["co ", "gdzie", "dlaczego", "kto", "który", "która", "jak"]
            )
        }
    }

    // MARK: - Reply templates

    private struct ReplyTemplate {
        let source: String
        let ukrainian: String
    }

    private static func templates(for intent: Intent, language: Language) -> [ReplyTemplate] {
        switch (intent, language) {
        case (.greeting, .en):
            [
                ReplyTemplate(source: "Hi! Good to see you.", ukrainian: "Привіт! Радий тебе бачити."),
                ReplyTemplate(source: "Hello, how are you?", ukrainian: "Привіт, як справи?"),
            ]
        case (.greeting, .de):
            [
                ReplyTemplate(source: "Hallo! Schön, dich zu sehen.", ukrainian: "Привіт! Радий тебе бачити."),
                ReplyTemplate(source: "Hallo, wie geht es dir?", ukrainian: "Привіт, як справи?"),
            ]
        case (.greeting, .pl):
            [
                ReplyTemplate(source: "Cześć! Miło cię widzieć.", ukrainian: "Привіт! Радий тебе бачити."),
                ReplyTemplate(source: "Cześć, jak się masz?", ukrainian: "Привіт, як справи?"),
            ]

        case (.wellBeingQuestion, .en):
            [
                ReplyTemplate(source: "I'm good, thanks.", ukrainian: "У мене все добре, дякую."),
                ReplyTemplate(source: "I'm doing well. How about you?", ukrainian: "Все добре. А в тебе?"),
                ReplyTemplate(source: "Not bad, thanks.", ukrainian: "Непогано, дякую."),
            ]
        case (.wellBeingQuestion, .de):
            [
                ReplyTemplate(source: "Mir geht es gut, danke.", ukrainian: "У мене все добре, дякую."),
                ReplyTemplate(source: "Gut, danke. Und dir?", ukrainian: "Добре, дякую. А в тебе?"),
                ReplyTemplate(source: "Es geht mir nicht schlecht.", ukrainian: "Непогано."),
            ]
        case (.wellBeingQuestion, .pl):
            [
                ReplyTemplate(source: "Dobrze, dzięki.", ukrainian: "Добре, дякую."),
                ReplyTemplate(source: "W porządku, a u ciebie?", ukrainian: "Все гаразд, а в тебе?"),
                ReplyTemplate(source: "Nieźle, dzięki.", ukrainian: "Непогано, дякую."),
            ]

        case (.timeQuestion, .en):
            [
                ReplyTemplate(source: "Around three works for me.", ukrainian: "Мені підходить приблизно третя."),
                ReplyTemplate(source: "Any time after five.", ukrainian: "Будь-коли після п'ятої."),
                ReplyTemplate(source: "Can we do it tomorrow?", ukrainian: "Можемо зробити це завтра?"),
            ]
        case (.timeQuestion, .de):
            [
                ReplyTemplate(source: "So gegen drei passt mir.", ukrainian: "Мені підходить приблизно третя."),
                ReplyTemplate(source: "Jederzeit nach fünf.", ukrainian: "Будь-коли після п'ятої."),
                ReplyTemplate(source: "Können wir es morgen machen?", ukrainian: "Можемо зробити це завтра?"),
            ]
        case (.timeQuestion, .pl):
            [
                ReplyTemplate(source: "Około trzeciej mi pasuje.", ukrainian: "Мені підходить приблизно третя."),
                ReplyTemplate(source: "Kiedykolwiek po piątej.", ukrainian: "Будь-коли після п'ятої."),
                ReplyTemplate(source: "Możemy zrobić to jutro?", ukrainian: "Можемо зробити це завтра?"),
            ]

        case (.invitation, .en):
            [
                ReplyTemplate(source: "Yes, I'd love to.", ukrainian: "Так, із задоволенням."),
                ReplyTemplate(source: "No, thank you.", ukrainian: "Ні, дякую."),
                ReplyTemplate(source: "Maybe later.", ukrainian: "Можливо пізніше."),
            ]
        case (.invitation, .de):
            [
                ReplyTemplate(source: "Ja, gerne.", ukrainian: "Так, із задоволенням."),
                ReplyTemplate(source: "Nein, danke.", ukrainian: "Ні, дякую."),
                ReplyTemplate(source: "Vielleicht später.", ukrainian: "Можливо пізніше."),
            ]
        case (.invitation, .pl):
            [
                ReplyTemplate(source: "Tak, chętnie.", ukrainian: "Так, із задоволенням."),
                ReplyTemplate(source: "Nie, dziękuję.", ukrainian: "Ні, дякую."),
                ReplyTemplate(source: "Może później.", ukrainian: "Можливо пізніше."),
            ]

        case (.yesNoQuestion, .en):
            [
                ReplyTemplate(source: "Yes, sure.", ukrainian: "Так, звісно."),
                ReplyTemplate(source: "Sorry, I can't right now.", ukrainian: "Вибач, зараз не можу."),
                ReplyTemplate(source: "Let me check and get back to you.", ukrainian: "Дай перевірю і скажу тобі."),
            ]
        case (.yesNoQuestion, .de):
            [
                ReplyTemplate(source: "Ja, klar.", ukrainian: "Так, звісно."),
                ReplyTemplate(source: "Tut mir leid, gerade nicht.", ukrainian: "Вибач, зараз не можу."),
                ReplyTemplate(source: "Ich schaue nach und melde mich.", ukrainian: "Перевірю і дам знати."),
            ]
        case (.yesNoQuestion, .pl):
            [
                ReplyTemplate(source: "Tak, jasne.", ukrainian: "Так, звісно."),
                ReplyTemplate(source: "Przepraszam, teraz nie mogę.", ukrainian: "Вибач, зараз не можу."),
                ReplyTemplate(source: "Sprawdzę i dam ci znać.", ukrainian: "Перевірю і дам знати."),
            ]

        case (.whQuestion, .en):
            [
                ReplyTemplate(source: "Let me think about that.", ukrainian: "Дай подумаю над цим."),
                ReplyTemplate(source: "Could you say that again?", ukrainian: "Можеш повторити?"),
                ReplyTemplate(source: "I'm not sure, actually.", ukrainian: "Насправді, я не впевнений."),
            ]
        case (.whQuestion, .de):
            [
                ReplyTemplate(source: "Lass mich kurz überlegen.", ukrainian: "Дай подумаю."),
                ReplyTemplate(source: "Kannst du das wiederholen?", ukrainian: "Можеш повторити?"),
                ReplyTemplate(source: "Ich bin mir nicht sicher.", ukrainian: "Я не впевнений."),
            ]
        case (.whQuestion, .pl):
            [
                ReplyTemplate(source: "Muszę się zastanowić.", ukrainian: "Мушу подумати."),
                ReplyTemplate(source: "Możesz to powtórzyć?", ukrainian: "Можеш повторити?"),
                ReplyTemplate(source: "Nie jestem pewien.", ukrainian: "Я не впевнений."),
            ]

        case (.statement, .en):
            [
                ReplyTemplate(source: "I see, thanks for sharing.", ukrainian: "Зрозуміло, дякую, що поділився."),
                ReplyTemplate(source: "Got it. What happened next?", ukrainian: "Зрозуміло. А що було далі?"),
            ]
        case (.statement, .de):
            [
                ReplyTemplate(source: "Verstehe, danke fürs Erzählen.", ukrainian: "Зрозуміло, дякую, що поділився."),
                ReplyTemplate(source: "Alles klar. Und was ist dann passiert?", ukrainian: "Зрозуміло. А що було далі?"),
            ]
        case (.statement, .pl):
            [
                ReplyTemplate(source: "Rozumiem, dzięki że powiedziałeś.", ukrainian: "Зрозуміло, дякую, що поділився."),
                ReplyTemplate(source: "Jasne. A co było dalej?", ukrainian: "Зрозуміло. А що було далі?"),
            ]
        }
    }
}
