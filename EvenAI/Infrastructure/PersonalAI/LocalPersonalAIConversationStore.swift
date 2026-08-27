import Foundation

/// Personal AI Chat's own conversation history — deliberately separate from
/// Glasses Chat (`LocalGlassesChatStore`) and AI Chat (`ChatServicing`).
/// `actor` over a JSON file, same pattern as `LocalPersonalMemoryStore`.
actor LocalPersonalAIConversationStore: PersonalAIConversationStore {

    private struct Document: Codable {
        var currentConversationID: UUID?
        var conversations: [UUID: [PersonalAIChatMessage]] = [:]
    }

    private let fileURL: URL
    private var document = Document()
    private var loaded = false

    init(directory: URL? = nil, ownerID: String? = nil) {
        let base = directory ?? Self.defaultDirectory()
        let name = ownerID.map { "personal-ai-conversations-\($0).json" } ?? "personal-ai-conversations.json"
        self.fileURL = base.appendingPathComponent(name)
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let sub = dir.appendingPathComponent("PersonalAI", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.personalAI.decode(Document.self, from: data) else { return }
        document = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.personalAI.encode(document) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    func loadConversation(id: UUID) async -> [PersonalAIChatMessage] {
        ensureLoaded()
        return document.conversations[id] ?? []
    }

    func append(_ message: PersonalAIChatMessage, conversationID: UUID) async {
        ensureLoaded()
        document.conversations[conversationID, default: []].append(message)
        document.currentConversationID = conversationID
        persist()
    }

    func replaceConversation(id: UUID, messages: [PersonalAIChatMessage]) async {
        ensureLoaded()
        document.conversations[id] = messages
        persist()
    }

    func currentConversationID() async -> UUID {
        ensureLoaded()
        if let id = document.currentConversationID { return id }
        let id = UUID()
        document.currentConversationID = id
        document.conversations[id] = []
        persist()
        return id
    }

    func startNewConversation() async -> UUID {
        ensureLoaded()
        let id = UUID()
        document.currentConversationID = id
        document.conversations[id] = []
        persist()
        return id
    }
}

/// In-memory conversation store for tests/previews.
actor InMemoryPersonalAIConversationStore: PersonalAIConversationStore {
    private var conversations: [UUID: [PersonalAIChatMessage]] = [:]
    private var current: UUID?

    init() {}

    func loadConversation(id: UUID) async -> [PersonalAIChatMessage] { conversations[id] ?? [] }
    func append(_ message: PersonalAIChatMessage, conversationID: UUID) async {
        conversations[conversationID, default: []].append(message)
        current = conversationID
    }
    func replaceConversation(id: UUID, messages: [PersonalAIChatMessage]) async {
        conversations[id] = messages
    }
    func currentConversationID() async -> UUID {
        if let current { return current }
        let id = UUID(); current = id; conversations[id] = []; return id
    }
    func startNewConversation() async -> UUID {
        let id = UUID(); current = id; conversations[id] = []; return id
    }
}
