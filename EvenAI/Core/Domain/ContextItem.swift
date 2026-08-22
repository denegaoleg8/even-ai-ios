import Foundation

/// Raw context material the user adds from the phone — a note, pasted
/// text, or a reference to an imported file — kept separate from
/// `AgentContextSession.turns` because it isn't itself a conversational
/// event; it's background material later fed into suggested-reply
/// generation (see the product design's "business meeting tomorrow"
/// example), or, deliberately, sometimes promoted into a turn via
/// `TurnSource.userNote`/`.importedContext`. This type is the raw
/// material before/without that promotion — nothing here implicitly
/// becomes a turn.
struct ContextItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case note
        case pastedText
        case importedFile
    }

    let id: UUID
    var kind: Kind
    var timestamp: Date
    /// The note/pasted text itself, or a human-readable label for an
    /// imported file (e.g. its filename) — the file's actual bytes are
    /// never modeled here; a file reference (id, storage path, etc.)
    /// belongs in `metadata`.
    var text: String
    var metadata: [String: String]?

    init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = .now,
        text: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.metadata = metadata
    }
}
