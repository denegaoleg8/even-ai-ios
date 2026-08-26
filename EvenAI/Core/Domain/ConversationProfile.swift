import Foundation

/// AI Conversation's user-facing behavior profile (formerly
/// `ConversationMode` — renamed as part of consolidating Live
/// Translation/Conversation Mode into one coherent "AI Conversation"
/// product; `.standard` became `.conversation`, keeping its ORIGINAL
/// persisted `rawValue` ("standard") so an existing install's saved
/// preference survives the rename unchanged). These are PRESENTATION
/// profiles, not separate pipelines — `AIConversationEngine` runs the
/// exact same STT/translation/reply machinery regardless of which one is
/// selected; only how much G2 screen real estate replies get, and (for
/// `.auto`) which of the other two profiles' presentation behavior is
/// currently in effect, changes.
///
/// - `.conversation`: optimized for 1-to-1 dialogue. Translation and
///   suggested replies both auto-display on G2 — a reply is added
///   directly below the header the moment it's ready (see
///   `GlassesPresentationLayer.pages(for:)`).
/// - `.meeting`: optimized for longer/group conversations. Listening,
///   translation, streaming, history, and Glasses Chat persistence are
///   all identical to `.conversation`; replies are still generated and
///   recorded, and DO reach G2 (see `GlassesPresentationLayer
///   .meetingConversationPages(for:previousTurn:)`), but never displace
///   the actively-shown transcript page — they're reachable as
///   additional swipeable pages, not auto-promoted to page 0. Replies
///   remain fully visible in Glasses Chat on the phone either way.
/// - `.auto`: same engine, same STT/translation pipeline as the other
///   two — `AIConversationEngine` continuously estimates which of
///   `.conversation`/`.meeting`'s PRESENTATION behavior currently fits
///   better, from simple, honest evidence only (recent turn cadence,
///   utterance length, whether the latest turn is a direct question) —
///   see `AIConversationEngine.effectiveDisplayProfile`'s own doc
///   comment for the exact heuristic. Deliberately NOT real speaker
///   diarization or anything requiring a model: this is a presentation
///   heuristic over data the engine already has, nothing more.
enum ConversationProfile: String, CaseIterable, Codable, Sendable {
    // Declaration order drives `allCases`' order, which is what the main
    // AI Conversation screen's profile picker iterates directly — `.auto`
    // first matches the product's own "Auto | Conversation | Meeting"
    // requirement and its role as the default, hides-the-choice-entirely
    // option for a normal user.
    case auto
    case conversation = "standard"
    case meeting

    var displayLabel: String {
        switch self {
        case .conversation: "Conversation"
        case .meeting: "Meeting"
        case .auto: "Auto"
        }
    }
}
