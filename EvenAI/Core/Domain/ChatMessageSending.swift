import Foundation

/// The one place a chat message is actually submitted — streamed via
/// `ChatServicing`, with the completed reply mirrored to the glasses via
/// `GlassesTransport`. `ChatViewModel.sendDraft()` goes through this type
/// rather than calling `ChatServicing.streamReply`/`GlassesTransport.sendText`
/// directly, so "submit and mirror" has exactly one implementation. (Kept
/// as its own type rather than inlined back into `ChatViewModel` after the
/// "Dictate to Chat" feature — its other original caller — was removed:
/// this separation isn't dictation-specific, and Live Translation's own
/// read-only Chat overlay deliberately does *not* go through this path —
/// see `LiveTranslationService`'s doc comment.)
protocol ChatMessageSending: Sendable {
    /// Streams `content` to `chatID` exactly as `ChatServicing.streamReply`
    /// does — every event is re-yielded unchanged, so a caller that renders
    /// live deltas (`ChatViewModel`) still gets them — while additionally
    /// mirroring the completed reply to the glasses once, on
    /// `.assistantMessageSaved`, the same way `ChatViewModel` already did
    /// before this type existed.
    func send(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}
