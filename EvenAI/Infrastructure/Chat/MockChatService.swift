import Foundation
import SwiftData

/// Mock chat service backed by real SwiftData persistence, so conversations
/// and messages survive app relaunch, but AI replies are canned/simulated
/// rather than calling a real backend. Used by tests and previews;
/// `NetworkChatService` is what the running app actually talks to.
actor MockChatService: ChatServicing {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer = PersistenceController.shared) {
        self.modelContainer = modelContainer
    }

    func fetchChats() async throws -> [Chat] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ChatEntity>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        var entities = try context.fetch(descriptor)
        if entities.isEmpty {
            entities = [try seedWelcomeChat(context: context)]
        }
        return entities.map { $0.toDomain() }
    }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        let context = ModelContext(modelContainer)
        guard let entity = try fetchChatEntity(id: id, context: context) else {
            throw ChatServiceError.chatNotFound
        }
        return entity.toDomain()
    }

    func createChat(title: String) async throws -> Chat {
        let context = ModelContext(modelContainer)
        let entity = ChatEntity(title: title)
        context.insert(entity)
        try context.save()
        return entity.toDomain()
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat {
        let context = ModelContext(modelContainer)
        guard let entity = try fetchChatEntity(id: id, context: context) else {
            throw ChatServiceError.chatNotFound
        }
        entity.title = title
        entity.updatedAt = .now
        try context.save()
        return entity.toDomain()
    }

    func deleteChat(id: Chat.ID) async throws {
        let context = ModelContext(modelContainer)
        guard let entity = try fetchChatEntity(id: id, context: context) else { return }
        context.delete(entity)
        try context.save()
    }

    func fetchMessages(chatID: Chat.ID) async throws -> [Message] {
        let context = ModelContext(modelContainer)
        guard let entity = try fetchChatEntity(id: chatID, context: context) else { return [] }
        return entity.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.toDomain() }
    }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let userMessage = try await self.saveUserMessage(chatID: chatID, content: content)
                    continuation.yield(.userMessageSaved(userMessage))

                    let reply = Self.mockReply(for: content)
                    for word in reply.split(separator: " ", omittingEmptySubsequences: true) {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(55))
                        continuation.yield(.assistantDelta(String(word) + " "))
                    }

                    let assistantMessage = try await self.saveAssistantMessage(chatID: chatID, content: reply)
                    continuation.yield(.assistantMessageSaved(assistantMessage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Persistence helpers

    private func fetchChatEntity(id: Chat.ID, context: ModelContext) throws -> ChatEntity? {
        var descriptor = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    private func seedWelcomeChat(context: ModelContext) throws -> ChatEntity {
        let welcome = ChatEntity(title: "Welcome to Even AI")
        let message = MessageEntity(
            role: .assistant,
            content: "Hi! I'm Even AI. How can I help?",
            chat: welcome
        )
        welcome.messages.append(message)
        welcome.lastMessagePreview = message.content
        context.insert(welcome)
        try context.save()
        return welcome
    }

    private func saveUserMessage(chatID: Chat.ID, content: String) throws -> Message {
        let context = ModelContext(modelContainer)
        guard let chatEntity = try fetchChatEntity(id: chatID, context: context) else {
            throw ChatServiceError.chatNotFound
        }
        let isFirstMessage = chatEntity.messages.isEmpty
        let message = MessageEntity(role: .user, content: content, chat: chatEntity)
        chatEntity.messages.append(message)
        chatEntity.updatedAt = .now
        chatEntity.lastMessagePreview = content
        if isFirstMessage && chatEntity.title == Chat.defaultTitle {
            chatEntity.title = Self.deriveTitle(from: content)
        }
        context.insert(message)
        try context.save()
        return message.toDomain()
    }

    private func saveAssistantMessage(chatID: Chat.ID, content: String) throws -> Message {
        let context = ModelContext(modelContainer)
        guard let chatEntity = try fetchChatEntity(id: chatID, context: context) else {
            throw ChatServiceError.chatNotFound
        }
        let message = MessageEntity(role: .assistant, content: content, chat: chatEntity)
        chatEntity.messages.append(message)
        chatEntity.updatedAt = .now
        chatEntity.lastMessagePreview = content
        context.insert(message)
        try context.save()
        return message.toDomain()
    }

    // MARK: - Mock reply generation

    private static func deriveTitle(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        guard !firstLine.isEmpty else { return Chat.defaultTitle }
        return firstLine.count <= 48 ? firstLine : String(firstLine.prefix(48)) + "…"
    }

    private static let mockReplies = [
        "That's a great question. Here's a thought: take it one step at a time, and let me know if you'd like more detail on any part of it.",
        "I hear you. This is a placeholder response from Even AI's mock assistant — once the real backend is connected, you'll get an actual model-generated reply here instead.",
        "Sure! Mock responses like this one stand in for now so the full chat experience — streaming, timestamps, persistence — can be built and tested end to end before any real AI is wired up.",
        "Got it. I'm running in mock mode right now, so this isn't a real answer yet, but the conversation flow around me — sending, streaming, saving — is fully functional."
    ]

    private static func mockReply(for prompt: String) -> String {
        let index = Int(prompt.hashValue.magnitude % UInt(mockReplies.count))
        return mockReplies[index]
    }
}

enum ChatServiceError: Error, Sendable {
    case chatNotFound
}
