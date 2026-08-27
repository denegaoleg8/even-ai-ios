import Foundation
import Observation

/// The app-level Personal AI orchestrator. Same lifecycle pattern as
/// `AgentContextStore` / `AIConversationEngine`: `@MainActor @Observable`,
/// constructed once in `EvenAIApp`, injected via `.environment(_:)`,
/// outlives any screen.
///
/// It owns the full Personal AI Chat turn:
///   1. apply memory commands found in this message (`remember` / `from now
///      on` / `forget` / style) — the "explicit current instruction" tier,
///   2. build personalization context (`PersonalAIContextBuilding`),
///   3. generate a reply (`PersonalAIModelProviding`),
///   4. persist history, then passively extract + merge durable memory.
///
/// It also exposes `personalContext(for:message:recentTurns:)` — the
/// **optional** seam a future G2 personalization step would call. Nothing in
/// the AI Conversation / G2 pipeline calls it in Phase 1; it exists so the
/// contract is real and tested. A failure anywhere in this type is contained
/// here: it never touches `AIConversationEngine`, translation, or local
/// suggested replies (there is no reference in either direction).
@MainActor
@Observable
final class PersonalAIService {

    enum Status: Equatable, Sendable {
        case idle
        case thinking
        case failed(String)
    }

    private(set) var messages: [PersonalAIChatMessage] = []
    private(set) var status: Status = .idle
    private(set) var memoryEnabled = true
    private(set) var conversationDoNotRemember = false
    /// A short, user-facing note about the last command applied
    /// ("Got it — I'll remember that.") — cleared on the next send.
    private(set) var lastCommandNote: String?
    /// The tier that answered the last turn — surfaced as a small caption.
    private(set) var lastProvider: PersonalAIGenerationResult.Provider?

    private let store: any PersonalMemoryStore
    private let contextBuilder: any PersonalAIContextBuilding
    private let modelProvider: any PersonalAIModelProviding
    private let conversationStore: any PersonalAIConversationStore
    private let commandProcessor: MemoryCommandProcessor
    private let extractor: any MemoryExtracting
    private let merger: MemoryMerger
    private let styleLearner: StyleProfileLearner

    private(set) var conversationID: UUID?

    init(
        store: any PersonalMemoryStore,
        contextBuilder: (any PersonalAIContextBuilding)? = nil,
        modelProvider: any PersonalAIModelProviding = OnDevicePersonalAIModelProvider(),
        conversationStore: any PersonalAIConversationStore = InMemoryPersonalAIConversationStore(),
        commandProcessor: MemoryCommandProcessor = MemoryCommandProcessor(),
        extractor: any MemoryExtracting = HeuristicMemoryExtractor(),
        merger: MemoryMerger = MemoryMerger(),
        styleLearner: StyleProfileLearner = StyleProfileLearner()
    ) {
        self.store = store
        self.contextBuilder = contextBuilder ?? DefaultPersonalAIContextBuilder(store: store)
        self.modelProvider = modelProvider
        self.conversationStore = conversationStore
        self.commandProcessor = commandProcessor
        self.extractor = extractor
        self.merger = merger
        self.styleLearner = styleLearner
    }

    // MARK: - Lifecycle

    /// Loads (or opens) the persistent Personal AI conversation. Personal AI
    /// Chat "always opens".
    func open() async {
        let id = await conversationStore.currentConversationID()
        conversationID = id
        messages = await conversationStore.loadConversation(id: id)
        memoryEnabled = await store.isMemoryEnabledGlobally()
        conversationDoNotRemember = await store.isConversationExcluded(id)
    }

    func startNewConversation() async {
        let id = await conversationStore.startNewConversation()
        conversationID = id
        messages = []
        conversationDoNotRemember = await store.isConversationExcluded(id)
        lastCommandNote = nil
    }

    // MARK: - Settings toggles

    func setMemoryEnabled(_ enabled: Bool) async {
        memoryEnabled = enabled
        await store.setMemoryEnabledGlobally(enabled)
    }

    func setConversationDoNotRemember(_ value: Bool) async {
        conversationDoNotRemember = value
        guard let conversationID else { return }
        await store.markConversationDoNotRemember(conversationID, value)
    }

    // MARK: - Send a turn

    func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, status != .thinking else { return }
        if conversationID == nil { await open() }
        guard let conversationID else { return }

        lastCommandNote = nil
        status = .thinking

        let userMessage = PersonalAIChatMessage(
            role: .user,
            text: text,
            eligibleForMemory: memoryEnabled && !conversationDoNotRemember
        )
        messages.append(userMessage)
        await conversationStore.append(userMessage, conversationID: conversationID)

        // 1. Apply memory commands in this message (explicit current-instruction tier).
        //    With memory globally disabled, nothing new is stored — a
        //    command is acknowledged as ignored rather than silently saved.
        if memoryEnabled {
            let outcomes = await commandProcessor.process(
                message: text,
                conversationID: conversationID,
                messageID: userMessage.id,
                store: store
            )
            if let note = outcomes.last?.summary { lastCommandNote = note }
        } else if !CommandInterpreter().interpret(text).isEmpty {
            lastCommandNote = "Memory is off — nothing was saved."
        }

        // 2. Build personalization context.
        let context = await contextBuilder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: text,
            recentConversation: recentConversationLines(),
            conversationID: conversationID
        ))

        // 3. Generate.
        do {
            let result = try await modelProvider.generate(PersonalAIGenerationRequest(
                personalContext: context,
                messages: Array(messages.dropLast()),
                userMessage: text
            ))
            let assistantMessage = PersonalAIChatMessage(role: .assistant, text: result.text)
            messages.append(assistantMessage)
            await conversationStore.append(assistantMessage, conversationID: conversationID)
            lastProvider = result.provider
            status = .idle

            // 4. Passive extraction — only for eligible turns.
            if userMessage.eligibleForMemory {
                await extractAndMerge(userMessage: userMessage, assistantMessage: assistantMessage, conversationID: conversationID)
                await learnStyle(from: text)
            }
        } catch let error as PersonalAIError {
            status = .failed(error.userFacingMessage)
            DiagnosticTrace.log("PERSONAL_AI_CHAT", "generation failed: \(error)")
        } catch {
            status = .failed(PersonalAIError.generationFailed("\(type(of: error))").userFacingMessage)
            DiagnosticTrace.log("PERSONAL_AI_CHAT", "generation failed: \(type(of: error))")
        }
    }

    // MARK: - Memory Center passthroughs
    //
    // The Memory Center reads/mutates memory through the app-level service
    // rather than reaching for the store directly — same reason views take
    // `ChatServicing` via DI, not `AppContainer`.

    func loadMemories(includeArchived: Bool = true) async -> [MemoryRecord] {
        let statuses: Set<MemoryStatus>? = includeArchived ? [.active, .archived, .superseded] : [.active]
        return await store.memories(matching: MemoryQuery(statuses: statuses, includeDisabled: true))
    }

    func loadRules() async -> [Rule] { await store.allRules() }

    func loadStyleProfile() async -> PersonalAIStyleProfile { await store.styleProfile() }

    func setMemoryEnabled(id: UUID, enabled: Bool) async { await store.setMemoryEnabled(id: id, enabled: enabled) }

    func setMemoryConfirmed(id: UUID, confirmed: Bool, pinned: Bool) async {
        await store.setMemoryConfirmed(id: id, confirmed: confirmed, pinned: pinned)
    }

    func deleteMemory(id: UUID) async { await store.deleteMemory(id: id) }

    func updateMemoryContent(id: UUID, content: String, category: MemoryCategory) async -> Bool {
        guard !SecretDetector.containsSecret(content) else { return false }
        let all = await store.allMemories()
        guard var record = all.first(where: { $0.id == id }) else { return false }
        record = record.touched()
        record.canonicalContent = content
        record.category = category
        record.userConfirmed = true
        record.entities = HeuristicMemoryExtractor.entities(in: content)
        await store.upsert([record])
        return true
    }

    /// Manual add from the Memory Center. Returns false if it looked like a
    /// secret (and was not stored).
    @discardableResult
    func addManualMemory(content: String, category: MemoryCategory, scope: MemoryScope = .global) async -> Bool {
        guard !SecretDetector.containsSecret(content) else { return false }
        let record = MemoryRecord(
            category: category, scope: scope,
            canonicalContent: content,
            entities: HeuristicMemoryExtractor.entities(in: content),
            confidence: 0.95, importance: 0.6, userConfirmed: true
        )
        await store.upsert([record])
        return true
    }

    @discardableResult
    func addManualRule(text: String, scope: MemoryScope = .global) async -> Bool {
        guard !SecretDetector.containsSecret(text) else { return false }
        await store.upsertRule(Rule(text: text, priority: .activeRule, scope: scope, source: .manualEntry))
        return true
    }

    func setRuleEnabled(id: UUID, enabled: Bool) async { await store.setRuleEnabled(id: id, enabled: enabled) }
    func deleteRule(id: UUID) async { await store.deleteRule(id: id) }

    func exportDocument() async -> PersonalMemoryDocument { await store.export() }

    // MARK: - G2 personalization seam (optional, unused by the live pipeline in Phase 1)

    /// Builds Personal AI context for a non-chat surface using the **exact
    /// same** `PersonalAIContextBuilding` contract Personal AI Chat uses.
    /// Provided so a future G2 personalization step (final speaker turn →
    /// translation immediately → local reply fallback immediately → this →
    /// improved replies if still relevant) has a real interface. It cannot
    /// delay translation, cannot stop listening, cannot end a session — it
    /// is a pure, cancellable read.
    nonisolated func personalContext(
        for surface: PersonalAISurface,
        message: String,
        recentTurns: [String],
        projectHints: [String] = [],
        now: Date = .now
    ) async -> PersonalAIContext {
        await contextBuilder.buildContext(PersonalAIContextRequest(
            surface: surface,
            userMessage: message,
            recentConversation: recentTurns,
            projectHints: projectHints,
            now: now
        ))
    }

    // MARK: - Internals

    private func recentConversationLines() -> [String] {
        messages.suffix(8).map { "\($0.role == .user ? "You" : "AI"): \($0.text)" }
    }

    private func extractAndMerge(userMessage: PersonalAIChatMessage, assistantMessage: PersonalAIChatMessage, conversationID: UUID) async {
        let exchange = PersonalAIExchange(
            conversationID: conversationID,
            surface: .personalChat,
            userText: userMessage.text,
            assistantText: assistantMessage.text,
            userMessageID: userMessage.id,
            assistantMessageID: assistantMessage.id
        )
        let existing = await store.allMemories()
        let excluded = await store.excludedConversationIDs()
        let candidates = await extractor.extract(
            from: exchange,
            existing: existing,
            excludedConversationIDs: excluded,
            memoryEnabled: memoryEnabled
        )
        for candidate in candidates {
            let current = await store.allMemories()
            switch merger.reconcile(candidate: candidate, against: current) {
            case .create(let record):
                await store.upsert([record])
            case .duplicate(_, let refreshed):
                await store.upsert([refreshed])
            case .mergeInto(_, let merged):
                await store.upsert([merged])
            case .supersede(let supersededID, let newRecord):
                await store.upsert([newRecord])
                if let old = current.first(where: { $0.id == supersededID }) {
                    var updated = old.touched()
                    updated.status = .superseded
                    updated.supersededByID = newRecord.id
                    await store.upsert([updated])
                }
            case .reject(let reason):
                DiagnosticTrace.log("PERSONAL_AI_MEMORY", "candidate rejected: \(reason)")
            }
        }
    }

    private func learnStyle(from text: String) async {
        let profile = await store.styleProfile()
        let updated = styleLearner.observing(userMessage: text, in: profile)
        if updated != profile {
            await store.updateStyleProfile(updated)
        }
    }
}
