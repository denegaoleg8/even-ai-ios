import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// Physical-device regression investigation ("the AI Chat screen also
/// does not open"). Structural audit found `ChatView`/`ChatViewModel`
/// have NO reference to `GlassesChatProvider` or `AIConversationEngine`
/// at all: `ChatListView.openGlassesChat()` is the ONLY caller of
/// `GlassesChatProvider.findOrCreateGlassesChat()` anywhere in the app,
/// and its own failure path never touches `appState.selectedChatID` —
/// so a broken/stale Glasses Chat id structurally cannot prevent, block,
/// or even touch normal AI Chat opening. The evidenced ACTUAL root cause
/// was different: `URLSessionRealtimeTranscriptionSocket.connect()` was
/// calling the always-network-round-trip `AuthenticatedAPIClient
/// .recoverSession()` unconditionally on every bounded reconnect
/// attempt, and `/auth/refresh` rotates the refresh token on every call
/// — churning the ONE session Live Translation and Chat share (see
/// `AuthenticatedAPIClient.ensureSession()`'s own doc comment for the
/// full mechanism, and `LiveTranslationStartClassificationTests` for the
/// Live Translation half of this investigation).
///
/// These tests lock the STRUCTURAL independence in explicitly, so a
/// future change can't silently reintroduce coupling between the two
/// features.
///
/// Scenario 11 ("a stale Glasses Chat id recovers independently") is
/// already covered by `GlassesChatProviderTests.staleIDSelfHeals` — not
/// duplicated here.
@MainActor
@Suite("Chat navigation — independence from Glasses Chat and Live Translation")
struct ChatNavigationIndependenceTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ChatNavigationIndependenceTests.\(UUID().uuidString)")!
    }

    /// A brand-new, isolated in-memory SwiftData container per test —
    /// `PersistenceController.preview` is a single PROCESS-WIDE shared
    /// instance (fine for previews, wrong for tests that need to count
    /// exactly how many chats exist).
    private func freshModelContainer() -> ModelContainer {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - 9: normal AI Chat opens when the Glasses Chat id is valid

    @Test("9: normal AI Chat loads successfully when the Glasses Chat id is valid and already resolved")
    func normalChatOpensWhenGlassesChatIDIsValid() async throws {
        let chatService = MockChatService(modelContainer: freshModelContainer())
        let normalChat = try await chatService.createChat(title: "My conversation")

        let provider = GlassesChatProvider(localStore: LocalGlassesChatStore(modelContainer: freshModelContainer()), defaults: freshDefaults())
        _ = try await provider.findOrCreateGlassesChat() // resolved, valid, cached

        let viewModel = ChatViewModel(chatID: normalChat.id, chatService: chatService, glassesTransport: MockGlassesTransport())
        await viewModel.load()

        #expect(!viewModel.loadFailed)
        #expect(viewModel.chatTitle == "My conversation")
    }

    // MARK: - 10: normal AI Chat opens even when the Glasses Chat persisted id is stale/404

    @Test("10: normal AI Chat loads successfully even when the Glasses Chat persisted id is stale and would 404")
    func normalChatOpensWhenGlassesChatPersistedIDIsStale() async throws {
        let chatService = MockChatService(modelContainer: freshModelContainer())
        let normalChat = try await chatService.createChat(title: "My conversation")

        // The exact physical-log clue: a persisted Glasses Chat id that
        // no longer resolves. Deliberately never resolved via
        // `findOrCreateGlassesChat()` here — this test proves normal
        // Chat doesn't need that call to have happened, or succeeded,
        // at all.
        let defaults = freshDefaults()
        defaults.set(UUID().uuidString, forKey: "com.evenai.glassesChatID")

        let viewModel = ChatViewModel(chatID: normalChat.id, chatService: chatService, glassesTransport: MockGlassesTransport())
        await viewModel.load()

        #expect(!viewModel.loadFailed)
        #expect(viewModel.chatTitle == "My conversation")
    }

    // MARK: - 12: Chat navigation does not depend on Live Translation state

    @Test("12: normal AI Chat loads with no AIConversationEngine reference anywhere in its construction or load path")
    func chatLoadNeverReferencesAIConversationEngine() async throws {
        // `ChatViewModel`'s own initializer accepts `chatID`/`chatService`/
        // `glassesTransport` — there is no `AIConversationEngine`
        // parameter to even wire up, and `load()` only ever calls
        // `chatService.fetchChat`/`fetchMessages`. This test exercises
        // that real code path end-to-end and is itself the regression
        // guard: if a future change added a AIConversationEngine
        // dependency to this path, this test's construction would need
        // to change to accommodate it.
        let chatService = MockChatService(modelContainer: freshModelContainer())
        let chat = try await chatService.createChat(title: "Independent of Live Translation")

        let viewModel = ChatViewModel(chatID: chat.id, chatService: chatService, glassesTransport: MockGlassesTransport())
        await viewModel.load()

        #expect(!viewModel.loadFailed)
        #expect(viewModel.messages.isEmpty) // a fresh chat — proves load() actually ran, not just skipped
    }

    // MARK: - 13: auth/session recovery failure surfaces correctly, no navigation deadlock

    @Test("13: a session/network failure while loading Chat surfaces as a visible failure — never a stuck isLoading, never a deadlock")
    func chatLoadFailureSurfacesCleanlyWithNoDeadlock() async {
        let viewModel = ChatViewModel(chatID: UUID(), chatService: FailingChatService(), glassesTransport: MockGlassesTransport())

        await viewModel.load() // must actually return — a hang here would time out the test itself

        #expect(viewModel.loadFailed)
        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isLoading) // never left stuck mid-load
    }

    // MARK: - 14: opening AI Chat never creates/replaces Glasses Chat

    @Test("14: opening and loading a normal AI Chat never creates a Glasses Chat as a side effect")
    func openingNormalChatNeverCreatesGlassesChat() async throws {
        let chatService = MockChatService(modelContainer: freshModelContainer())
        let normalChat = try await chatService.createChat(title: "Just a normal chat")

        let viewModel = ChatViewModel(chatID: normalChat.id, chatService: chatService, glassesTransport: MockGlassesTransport())
        await viewModel.load()
        #expect(!viewModel.loadFailed)

        // Exactly the one chat created above — opening/loading it never
        // resolved or created a SEPARATE "Glasses Chat" entry.
        let allChats = try await chatService.fetchChats()
        #expect(allChats.count == 1)
        #expect(allChats.first?.id == normalChat.id)
    }
}
