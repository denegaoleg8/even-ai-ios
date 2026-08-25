import Foundation

/// Conversation Mode preset (major redesign pass, Section 8 — "Meeting /
/// Group-Call Reliability Mode"). `.standard` is today's default
/// behavior unchanged: translation and suggested replies both auto-
/// display on G2. `.meeting` keeps everything else identical (listening,
/// translation, streaming, history, Glasses Chat persistence, replies
/// still generated and recorded) but suppresses the AUTOMATIC reply
/// display on G2 — replies are lower priority in a meeting, where the
/// screen should stay dedicated to the conversation transcript rather
/// than being replaced by a suggested-reply page after every turn.
/// Replies remain fully visible in Glasses Chat on the phone either way.
enum ConversationMode: String, CaseIterable, Codable, Sendable {
    case standard
    case meeting

    var displayLabel: String {
        switch self {
        case .standard: "Standard"
        case .meeting: "Meeting"
        }
    }
}
