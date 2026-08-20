import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    let chatID: Chat.ID
    var chatTitle: String = Chat.defaultTitle
    var messages: [Message] = []
    var draftText: String = ""
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var isAwaitingFirstToken = false
    /// True when the most recent `load()` failed — lets the view tell "new,
    /// empty conversation" apart from "couldn't reach the backend to fetch
    /// this conversation's history," which look identical if you only
    /// check `messages.isEmpty`.
    private(set) var loadFailed = false

    private let chatService: ChatServicing
    private let glassesTransport: GlassesTransport
    private var streamingMessageID: Message.ID?

    /// No default — see `ChatListViewModel.init`'s note; same reasoning.
    init(chatID: Chat.ID, chatService: ChatServicing, glassesTransport: GlassesTransport) {
        self.chatID = chatID
        self.chatService = chatService
        self.glassesTransport = glassesTransport
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let chat = try await chatService.fetchChat(id: chatID)
            chatTitle = chat.title
            messages = try await chatService.fetchMessages(chatID: chatID)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    func sendDraft() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        draftText = ""
        isSending = true
        isAwaitingFirstToken = true
        var didReceiveUserMessage = false
        defer {
            isSending = false
            isAwaitingFirstToken = false
            streamingMessageID = nil
        }

        do {
            let stream = chatService.streamReply(chatID: chatID, content: text)
            for try await event in stream {
                if case .userMessageSaved = event { didReceiveUserMessage = true }
                handle(event)
            }
        } catch {
            handleStreamFailure(originalText: text, didReceiveUserMessage: didReceiveUserMessage)
        }

        if let chat = try? await chatService.fetchChat(id: chatID) {
            chatTitle = chat.title
        }
    }

    private func handle(_ event: ChatStreamEvent) {
        switch event {
        case .userMessageSaved(let message):
            messages.append(message)

        case .assistantDelta(let delta):
            isAwaitingFirstToken = false
            if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].content += delta
            } else {
                let placeholder = Message(chatID: chatID, role: .assistant, content: delta, status: .streaming)
                streamingMessageID = placeholder.id
                messages.append(placeholder)
            }

        case .assistantMessageSaved(let message):
            if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            streamingMessageID = nil
            mirrorToGlasses(message)
        }
    }

    /// Best-effort, one-way mirror of a just-completed reply — fired exactly
    /// once per `sendDraft()` call, only from this `.assistantMessageSaved`
    /// branch of the event this send's own stream produced (never from
    /// `load()`, which assigns `messages` directly from history and never
    /// touches `handle(_:)` — so switching to or reloading an existing chat
    /// never re-mirrors old replies). Never awaited by `sendDraft()`'s own
    /// loop, so a slow or hung BLE write can never delay clearing
    /// `isSending`/unlocking the input bar, and never affects Chat's own
    /// success/failure state. Silently no-ops if glasses aren't connected
    /// (`GlassesTransportError.notConnected`) — Chat has no dependency on,
    /// and never observes, glasses connection state.
    private func mirrorToGlasses(_ message: Message) {
        guard !message.content.isEmpty else { return }
        Task { [glassesTransport] in
            try? await glassesTransport.sendText(message.content)
        }
    }

    /// Never silently drop a send failure. Three distinct cases, each
    /// needing a different visible outcome instead of vanishing:
    private func handleStreamFailure(originalText: String, didReceiveUserMessage: Bool) {
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            // We were mid-reply when the connection broke — the partial
            // text is not a real, complete answer, so mark it failed
            // rather than leaving it looking like a normal short reply.
            messages[index].status = .failed
        } else if didReceiveUserMessage {
            // The user's message made it to the backend, but no reply
            // arrived at all — surface that explicitly.
            messages.append(Message(chatID: chatID, role: .assistant, content: "", status: .failed))
        } else {
            // Never even connected. Restore the draft's content into the
            // transcript as a locally-failed message instead of just
            // discarding what the user typed with no trace of it.
            messages.append(Message(chatID: chatID, role: .user, content: originalText, status: .failed))
        }
    }
}
