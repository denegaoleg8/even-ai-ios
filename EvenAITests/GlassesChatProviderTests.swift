import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// `GlassesChatProvider` finds or lazily creates the one persistent
/// "Glasses Chat" conversation — identity is a `Chat.ID` persisted in
/// `UserDefaults`, not the chat's title (see the type's own doc comment
/// for why title matching was explicitly avoided). Local-first
/// architecture pass: this provider is now backed directly by
/// `LocalGlassesChatStore` (SwiftData), with NO `ChatServicing`/network
/// dependency at all — every test here uses a fresh, isolated in-memory
/// `ModelContainer` plus a fresh, uniquely-named `UserDefaults(suiteName:)`,
/// so tests stay fully isolated from each other, the real app's defaults,
/// AND (unlike the old network-recording design this replaced) from any
/// network layer whatsoever — there is none to fake anymore.
@MainActor
@Suite("GlassesChatProvider (local-first)")
struct GlassesChatProviderTests {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "GlassesChatProviderTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func freshLocalStore() -> LocalGlassesChatStore {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return LocalGlassesChatStore(modelContainer: container)
    }

    @Test("no persisted id yet: creates exactly one chat, titled 'Glasses Chat', with no network involved")
    func createsOnFirstUse() async throws {
        let provider = GlassesChatProvider(localStore: freshLocalStore(), defaults: freshDefaults())

        let chat = try await provider.findOrCreateGlassesChat()

        #expect(chat.title == GlassesChatProvider.displayTitle)
    }

    @Test("a persisted id that still resolves locally is reused — no new chat is created")
    func reusesPersistedID() async throws {
        let store = freshLocalStore()
        let existing = await store.findOrCreateChat(id: nil, title: "Glasses Chat")
        let defaults = freshDefaults()
        defaults.set(existing.id.uuidString, forKey: "com.evenai.glassesChatID")
        let provider = GlassesChatProvider(localStore: store, defaults: defaults)

        let chat = try await provider.findOrCreateGlassesChat()

        #expect(chat.id == existing.id)
    }

    @Test("calling twice never creates a second chat — the second call reuses the in-memory cached result")
    func secondCallReusesCachedResult() async throws {
        let provider = GlassesChatProvider(localStore: freshLocalStore(), defaults: freshDefaults())

        let first = try await provider.findOrCreateGlassesChat()
        let second = try await provider.findOrCreateGlassesChat()

        #expect(first.id == second.id)
    }

    @Test("two concurrent callers, before anything is cached, still create only one chat")
    func concurrentCallersCreateOnlyOneChat() async throws {
        let provider = GlassesChatProvider(localStore: freshLocalStore(), defaults: freshDefaults())

        async let first = provider.findOrCreateGlassesChat()
        async let second = provider.findOrCreateGlassesChat()
        let (chatA, chatB) = try await (first, second)

        #expect(chatA.id == chatB.id)
    }

    @Test("a persisted id that no longer resolves locally self-heals by creating a fresh chat")
    func staleIDSelfHeals() async throws {
        let defaults = freshDefaults()
        let staleID = UUID()
        defaults.set(staleID.uuidString, forKey: "com.evenai.glassesChatID")
        let provider = GlassesChatProvider(localStore: freshLocalStore(), defaults: defaults)

        let chat = try await provider.findOrCreateGlassesChat()

        #expect(chat.id != staleID)
    }

    @Test("invalidateCache() forces the next call to re-resolve rather than reusing the in-memory result")
    func invalidateCacheForcesReResolution() async throws {
        let provider = GlassesChatProvider(localStore: freshLocalStore(), defaults: freshDefaults())

        let first = try await provider.findOrCreateGlassesChat()
        provider.invalidateCache()
        // The persisted id still resolves locally (freshDefaults wasn't
        // cleared), so this is a REUSE, not a second chat.
        let second = try await provider.findOrCreateGlassesChat()

        #expect(first.id == second.id)
    }

    // MARK: - Local-first / offline guarantees (§10, §18 items 11-12 of the
    // local-first architecture pass)

    @Test("Glasses Chat resolves and accepts turns with ZERO ChatServicing/network dependency configured at all")
    func worksWithNoNetworkDependencyWhatsoever() async throws {
        // No ChatServicing, no AuthenticatedAPIClient, no apiClient of any
        // kind is even constructible here — GlassesChatProvider's only
        // dependency is LocalGlassesChatStore (SwiftData) and UserDefaults.
        let provider = GlassesChatProvider(localStore: freshLocalStore(), defaults: freshDefaults())

        let chat = try await provider.findOrCreateGlassesChat()
        let message = try await provider.appendTurn(originalText: "hello", translation: "привіт")

        #expect(message?.chatID == chat.id)
        #expect(message?.content.contains("hello") == true)
        #expect(message?.content.contains("привіт") == true)
    }

    @Test("appended turns persist and reload from the local store across a fresh GlassesChatProvider instance")
    func turnsPersistAndReloadLocally() async throws {
        let store = freshLocalStore()
        let defaults = freshDefaults()
        let provider = GlassesChatProvider(localStore: store, defaults: defaults)

        let chat = try await provider.findOrCreateGlassesChat()
        _ = try await provider.appendTurn(originalText: "first turn", translation: "перший")
        _ = try await provider.appendTurn(originalText: "second turn", translation: "другий")

        // A brand-new provider instance (simulating an app relaunch),
        // sharing only the same underlying store and persisted defaults —
        // proves history survives independent of any one provider's
        // in-memory cache.
        let relaunchedProvider = GlassesChatProvider(localStore: store, defaults: defaults)
        let reresolvedChat = try await relaunchedProvider.findOrCreateGlassesChat()
        let messages = await store.fetchMessages(chatID: chat.id)

        #expect(reresolvedChat.id == chat.id)
        #expect(messages.count == 2)
        #expect(messages.map(\.content).contains { $0.contains("first turn") })
        #expect(messages.map(\.content).contains { $0.contains("second turn") })
    }
}
