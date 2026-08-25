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
    /// Non-`nil` ONLY when `load()`'s failure was specifically the
    /// backend rate-limiting session recovery (`/auth/device` → `429` —
    /// see `AuthenticatedAPIClientError.rateLimited`'s own doc comment).
    /// Lets the view show a truthful, non-alarming "Session temporarily
    /// unavailable — retry in Xs" state instead of the generic "Can't
    /// Connect" copy, which would wrongly suggest a network problem when
    /// the backend is actually reachable and working — it's just
    /// declining new anonymous sessions from this device for a known,
    /// bounded time.
    private(set) var rateLimitedRetryAfterSeconds: Int?

    private let chatService: ChatServicing
    private let messageSender: ChatMessageSending
    private var streamingMessageID: Message.ID?

    /// No default — see `ChatListViewModel.init`'s note; same reasoning.
    /// Constructor signature deliberately unchanged even though sending no
    /// longer goes straight through `chatService` — `messageSender` (built
    /// here, not injected) wraps the same `chatService`/`glassesTransport`
    /// pair this type always took, so `ChatView`/`RootView`/existing tests
    /// need no changes — see `ChatMessageSending`'s doc comment.
    init(chatID: Chat.ID, chatService: ChatServicing, glassesTransport: GlassesTransport) {
        self.chatID = chatID
        self.chatService = chatService
        self.messageSender = ChatMessageSender(chatService: chatService, glassesTransport: glassesTransport)
    }

    func load() async {
        DiagnosticTrace.log("CHAT_LOAD_START", "chatID=\(chatID)")
        isLoading = true
        defer { isLoading = false }
        do {
            let chat = try await chatService.fetchChat(id: chatID)
            chatTitle = chat.title
            messages = try await chatService.fetchMessages(chatID: chatID)
            loadFailed = false
            rateLimitedRetryAfterSeconds = nil
            // Reaching here means whatever credential this request used
            // (recovered proactively by `AuthenticatedAPIClient
            // .performOnce`'s reactive 401 path if needed) was accepted
            // by the backend — the same shared session Live Translation
            // authenticates through. `type=` isn't independently known
            // at this layer (`ChatViewModel` only holds `ChatServicing`,
            // never `AuthenticatedAPIClient` directly — see this
            // constructor's own doc comment on why that boundary is
            // deliberate), so this reports the fact of success without
            // over-reaching into a layer this type shouldn't depend on.
            DiagnosticTrace.log("CHAT_AUTH_READY", "chatID=\(chatID)")
            DiagnosticTrace.log("CHAT_LOAD_SUCCESS", "chatID=\(chatID) messageCount=\(messages.count)")
        } catch {
            loadFailed = true
            if let apiError = error as? AuthenticatedAPIClientError {
                if case .rateLimited(let seconds) = apiError {
                    rateLimitedRetryAfterSeconds = seconds
                    DiagnosticTrace.log("CHAT_AUTH_FAILED", "chatID=\(chatID) reason=rateLimited retryAfterSeconds=\(seconds)")
                } else {
                    rateLimitedRetryAfterSeconds = nil
                    if Self.isAuthFailure(apiError) {
                        DiagnosticTrace.log("CHAT_AUTH_FAILED", "chatID=\(chatID) reason=\(apiError)")
                    }
                }
            }
            DiagnosticTrace.log("CHAT_LOAD_FAILED", "chatID=\(chatID) errorType=\(type(of: error)) errorMessage=\(error)")
        }
    }

    /// Whether `error` reflects a genuine session/credential problem —
    /// as opposed to an ordinary network hiccup or a backend error that
    /// has nothing to do with authentication — matching
    /// `AuthenticatedAPIClient.classifyRecoveryFailure(_:)`'s own
    /// distinction (kept independently here since that method is
    /// private to a different type; both classify the exact same
    /// underlying `AuthenticatedAPIClientError` cases). `.rateLimited` is
    /// handled separately by the caller (`rateLimitedRetryAfterSeconds`),
    /// never routed through this — it's a distinct UI state, not a
    /// generic auth failure.
    private static func isAuthFailure(_ error: AuthenticatedAPIClientError) -> Bool {
        switch error {
        case .notAuthenticated, .sessionExpired:
            return true
        case .http(let status, _):
            return status == 401
        case .offline, .invalidResponse, .underlying, .rateLimited:
            return false
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
            let stream = messageSender.send(chatID: chatID, content: text)
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
            // Mirroring to the glasses now happens inside `messageSender`
            // itself (see `ChatMessageSender`) — this branch only updates
            // this view model's own `messages`, same as every other event.
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
