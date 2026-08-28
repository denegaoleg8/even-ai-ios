import Foundation

/// Personal AI Chat's own conversation history — deliberately separate from
/// Glasses Chat (`LocalGlassesChatStore`) and AI Chat (`ChatServicing`).
/// `actor` over a JSON file, same pattern as `LocalPersonalMemoryStore`.
///
/// Phase 2: conversations are first-class `PersonalAIConversation` records
/// and messages carry sync metadata, so both sync / back up / restore. The
/// document I/O goes through an injected `DocumentFileStoring`
/// (`PlaintextDocumentFile` by default, `EncryptedDocumentFile` in
/// production). A Phase 1 document (`[UUID: [PersonalAIChatMessage]]`) is
/// migrated forward on first load.
actor LocalPersonalAIConversationStore: PersonalAIConversationStore {

    struct Document: Codable {
        var schemaVersion: Int = 2
        var currentConversationID: UUID?
        var conversations: [PersonalAIConversation] = []
        var messages: [PersonalAIChatMessage] = []
        /// Legacy Phase 1 shape — decoded then migrated, never written.
        var legacyConversations: [UUID: [PersonalAIChatMessage]]?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, currentConversationID, conversations, messages
            case legacyConversations = "conversationsLegacy"
        }
        // Phase 1 used the key "conversations" for the legacy map; Phase 2
        // uses it for the record array. Distinguish by trying each shape.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicKey.self)
            schemaVersion = (try? c.decode(Int.self, forKey: DynamicKey("schemaVersion"))) ?? 1
            currentConversationID = try? c.decode(UUID.self, forKey: DynamicKey("currentConversationID"))
            messages = (try? c.decode([PersonalAIChatMessage].self, forKey: DynamicKey("messages"))) ?? []
            if let records = try? c.decode([PersonalAIConversation].self, forKey: DynamicKey("conversations")) {
                conversations = records
            } else if let legacy = try? c.decode([UUID: [PersonalAIChatMessage]].self, forKey: DynamicKey("conversations")) {
                legacyConversations = legacy
                conversations = []
            } else {
                conversations = []
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(schemaVersion, forKey: DynamicKey("schemaVersion"))
            try c.encodeIfPresent(currentConversationID, forKey: DynamicKey("currentConversationID"))
            try c.encode(conversations, forKey: DynamicKey("conversations"))
            try c.encode(messages, forKey: DynamicKey("messages"))
        }
        init() {}

        struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    private let fileURL: URL
    private let ownerID: String?
    private let fileStore: DocumentFileStoring
    private var document = Document()
    private var loaded = false

    init(directory: URL? = nil, ownerID: String? = nil, fileStore: DocumentFileStoring = PlaintextDocumentFile()) {
        let base = directory ?? Self.defaultDirectory()
        let name = ownerID.map { "personal-ai-conversations-\($0).json" } ?? "personal-ai-conversations.json"
        self.fileURL = base.appendingPathComponent(name)
        self.ownerID = ownerID
        self.fileStore = fileStore
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
        let bytes: Data?
        do { bytes = try fileStore.read(from: fileURL) } catch { bytes = nil }
        guard let bytes, let decoded = try? JSONDecoder.personalAI.decode(Document.self, from: bytes) else { return }
        document = decoded
        migrateLegacyIfNeeded()
    }

    /// Phase 1 stored messages as `[conversationID: [message]]` with no
    /// conversation records and no message sync fields. Flatten into the
    /// Phase 2 shape, stamping `conversationID` onto each message.
    private func migrateLegacyIfNeeded() {
        guard let legacy = document.legacyConversations else { return }
        var convs: [PersonalAIConversation] = []
        var msgs: [PersonalAIChatMessage] = []
        for (convID, legacyMessages) in legacy {
            var stamped = legacyMessages.map { m -> PersonalAIChatMessage in
                var copy = m
                copy.conversationID = convID
                return copy
            }
            stamped.sort { $0.timestamp < $1.timestamp }
            convs.append(PersonalAIConversation(
                id: convID,
                createdAt: stamped.first?.timestamp ?? .now,
                updatedAt: stamped.last?.timestamp ?? .now,
                lastMessageAt: stamped.last?.timestamp,
                messageCount: stamped.count
            ))
            msgs.append(contentsOf: stamped)
        }
        document.conversations = convs
        document.messages = msgs
        document.legacyConversations = nil
        document.schemaVersion = 2
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder.personalAI.encode(document) else { return }
        try? fileStore.write(data, to: fileURL)
    }

    // MARK: - Phase 1 API

    func loadConversation(id: UUID) async -> [PersonalAIChatMessage] {
        ensureLoaded()
        return document.messages
            .filter { $0.conversationID == id && $0.deletedAt == nil }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func append(_ message: PersonalAIChatMessage, conversationID: UUID) async {
        ensureLoaded()
        var stamped = message
        stamped.conversationID = conversationID
        stamped.ownerID = stamped.ownerID ?? ownerID
        document.messages.append(stamped)
        document.currentConversationID = conversationID
        touchConversation(conversationID, lastMessageAt: stamped.timestamp)
        persist()
    }

    func replaceConversation(id: UUID, messages: [PersonalAIChatMessage]) async {
        ensureLoaded()
        document.messages.removeAll { $0.conversationID == id }
        document.messages.append(contentsOf: messages.map { m in
            var copy = m; copy.conversationID = id; return copy
        })
        touchConversation(id, lastMessageAt: messages.map(\.timestamp).max())
        persist()
    }

    func currentConversationID() async -> UUID {
        ensureLoaded()
        if let id = document.currentConversationID { return id }
        let id = UUID()
        document.currentConversationID = id
        ensureConversationRecord(id)
        persist()
        return id
    }

    func startNewConversation() async -> UUID {
        ensureLoaded()
        let id = UUID()
        document.currentConversationID = id
        ensureConversationRecord(id)
        persist()
        return id
    }

    // MARK: - Phase 2 API

    func allConversations() async -> [PersonalAIConversation] {
        ensureLoaded()
        return document.conversations
    }

    func allMessages() async -> [PersonalAIChatMessage] {
        ensureLoaded()
        return document.messages
    }

    func upsertConversation(_ conversation: PersonalAIConversation) async {
        ensureLoaded()
        if let idx = document.conversations.firstIndex(where: { $0.id == conversation.id }) {
            document.conversations[idx] = conversation
        } else {
            document.conversations.append(conversation)
        }
        persist()
    }

    func upsertMessages(_ messages: [PersonalAIChatMessage]) async {
        ensureLoaded()
        for message in messages {
            if let idx = document.messages.firstIndex(where: { $0.id == message.id }) {
                document.messages[idx] = message
            } else {
                document.messages.append(message)
            }
            ensureConversationRecord(message.conversationID)
        }
        persist()
    }

    func setDoNotRemember(_ conversationID: UUID, _ value: Bool) async {
        ensureLoaded()
        ensureConversationRecord(conversationID)
        if let idx = document.conversations.firstIndex(where: { $0.id == conversationID }) {
            document.conversations[idx] = document.conversations[idx].touched()
            document.conversations[idx].doNotRemember = value
        }
        for i in document.messages.indices where document.messages[i].conversationID == conversationID {
            document.messages[i].eligibleForMemory = !value
        }
        persist()
    }

    func replaceAllConversations(_ conversations: [PersonalAIConversation], messages: [PersonalAIChatMessage]) async {
        ensureLoaded()
        document.conversations = conversations
        document.messages = messages
        if let newest = conversations.max(by: { ($0.lastMessageAt ?? $0.updatedAt) < ($1.lastMessageAt ?? $1.updatedAt) }) {
            document.currentConversationID = newest.id
        }
        persist()
    }

    func wipe() async {
        loaded = true
        document = Document()
        persist()
    }

    // MARK: - Helpers

    private func ensureConversationRecord(_ id: UUID) {
        guard !document.conversations.contains(where: { $0.id == id }) else { return }
        document.conversations.append(PersonalAIConversation(id: id, ownerID: ownerID))
    }

    private func touchConversation(_ id: UUID, lastMessageAt: Date?) {
        ensureConversationRecord(id)
        guard let idx = document.conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = document.conversations[idx].touched()
        conv.lastMessageAt = lastMessageAt ?? conv.lastMessageAt
        conv.messageCount = document.messages.filter { $0.conversationID == id && $0.deletedAt == nil }.count
        document.conversations[idx] = conv
    }
}

/// In-memory conversation store for tests/previews — same semantics, no disk.
actor InMemoryPersonalAIConversationStore: PersonalAIConversationStore {
    private var conversations: [PersonalAIConversation] = []
    private var messages: [PersonalAIChatMessage] = []
    private var current: UUID?

    init() {}

    func loadConversation(id: UUID) async -> [PersonalAIChatMessage] {
        messages.filter { $0.conversationID == id && $0.deletedAt == nil }.sorted { $0.timestamp < $1.timestamp }
    }
    func append(_ message: PersonalAIChatMessage, conversationID: UUID) async {
        var stamped = message; stamped.conversationID = conversationID
        messages.append(stamped)
        current = conversationID
        ensureRecord(conversationID, lastMessageAt: stamped.timestamp)
    }
    func replaceConversation(id: UUID, messages newMessages: [PersonalAIChatMessage]) async {
        messages.removeAll { $0.conversationID == id }
        messages.append(contentsOf: newMessages.map { m in var c = m; c.conversationID = id; return c })
        ensureRecord(id, lastMessageAt: newMessages.map(\.timestamp).max())
    }
    func currentConversationID() async -> UUID {
        if let current { return current }
        let id = UUID(); current = id; ensureRecord(id, lastMessageAt: nil); return id
    }
    func startNewConversation() async -> UUID {
        let id = UUID(); current = id; ensureRecord(id, lastMessageAt: nil); return id
    }
    func allConversations() async -> [PersonalAIConversation] { conversations }
    func allMessages() async -> [PersonalAIChatMessage] { messages }
    func upsertConversation(_ conversation: PersonalAIConversation) async {
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[idx] = conversation }
        else { conversations.append(conversation) }
    }
    func upsertMessages(_ incoming: [PersonalAIChatMessage]) async {
        for message in incoming {
            if let idx = messages.firstIndex(where: { $0.id == message.id }) { messages[idx] = message }
            else { messages.append(message) }
        }
    }
    func setDoNotRemember(_ conversationID: UUID, _ value: Bool) async {
        ensureRecord(conversationID, lastMessageAt: nil)
        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[idx].doNotRemember = value
            conversations[idx] = conversations[idx].touched()
        }
        for i in messages.indices where messages[i].conversationID == conversationID {
            messages[i].eligibleForMemory = !value
        }
    }
    func replaceAllConversations(_ newConversations: [PersonalAIConversation], messages newMessages: [PersonalAIChatMessage]) async {
        conversations = newConversations
        messages = newMessages
        if let newest = newConversations.max(by: { ($0.lastMessageAt ?? $0.updatedAt) < ($1.lastMessageAt ?? $1.updatedAt) }) {
            current = newest.id
        } else if let anyConv = newMessages.first?.conversationID {
            current = anyConv
        }
    }
    func wipe() async {
        conversations = []; messages = []; current = nil
    }

    private func ensureRecord(_ id: UUID, lastMessageAt: Date?) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            var c = conversations[idx]
            c.lastMessageAt = lastMessageAt ?? c.lastMessageAt
            c.messageCount = messages.filter { $0.conversationID == id && $0.deletedAt == nil }.count
            conversations[idx] = c
        } else {
            conversations.append(PersonalAIConversation(id: id, lastMessageAt: lastMessageAt))
        }
    }
}
