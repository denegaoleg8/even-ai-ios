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

    // MARK: Phase 2 — cloud sync / backup observable state
    /// Which kind of cloud is actually wired. `.notConfigured` in a shipping
    /// build today — the UI must not imply cross-device durability unless
    /// this is `.connected`.
    private(set) var cloudEnvironment: PersonalCloudEnvironment = .notConfigured
    private(set) var cloudSyncEnabled = false
    private(set) var syncStatus: PersonalCloudOperationStatus = .idle
    private(set) var backupStatus: PersonalCloudOperationStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var lastBackupAt: Date?
    private(set) var pendingSyncCount = 0
    private(set) var isAuthenticated = false

    /// True only when memory genuinely survives loss of this device.
    var cloudProvidesDurability: Bool { cloudEnvironment.providesDurability }
    /// Whether a real or simulated cloud service exists to sync against.
    private var hasCloudService: Bool { cloud?.cloudService != nil }

    private let store: any PersonalMemoryStore
    private let contextBuilder: any PersonalAIContextBuilding
    private let modelProvider: any PersonalAIModelProviding
    private let conversationStore: any PersonalAIConversationStore
    private let commandProcessor: MemoryCommandProcessor
    private let extractor: any MemoryExtracting
    private let merger: MemoryMerger
    private let styleLearner: StyleProfileLearner
    /// Phase 2 cloud dependencies. `nil` for tests / previews that don't
    /// exercise sync — the whole Phase 1 chat + memory path works unchanged
    /// without it.
    private let cloud: PersonalAICloudBundle?

    private(set) var conversationID: UUID?

    init(
        store: any PersonalMemoryStore,
        contextBuilder: (any PersonalAIContextBuilding)? = nil,
        modelProvider: any PersonalAIModelProviding = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, OnDevicePersonalAIModelProvider()),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ]),
        conversationStore: any PersonalAIConversationStore = InMemoryPersonalAIConversationStore(),
        commandProcessor: MemoryCommandProcessor = MemoryCommandProcessor(),
        extractor: any MemoryExtracting = HeuristicMemoryExtractor(),
        merger: MemoryMerger = MemoryMerger(),
        styleLearner: StyleProfileLearner = StyleProfileLearner(),
        cloud: PersonalAICloudBundle? = nil
    ) {
        self.store = store
        self.contextBuilder = contextBuilder ?? DefaultPersonalAIContextBuilder(store: store)
        self.modelProvider = modelProvider
        self.conversationStore = conversationStore
        self.commandProcessor = commandProcessor
        self.extractor = extractor
        self.merger = merger
        self.styleLearner = styleLearner
        self.cloud = cloud
        self.cloudEnvironment = cloud?.environment ?? .notConfigured
    }

    // MARK: - Lifecycle

    /// Loads (or opens) the persistent Personal AI conversation. Personal AI
    /// Chat "always opens".
    func open() async {
        if let cloud {
            let state = await cloud.dataStore.syncState()
            // With no cloud service wired, sync is impossible — never let a
            // stale persisted `cloudSyncEnabled` flag imply otherwise.
            cloudSyncEnabled = hasCloudService && state.cloudSyncEnabled
            lastSyncedAt = state.lastSyncSucceededAt
            lastBackupAt = state.lastBackupSucceededAt
            pendingSyncCount = state.pendingMutationCount
            isAuthenticated = cloud.ownerBox.ownerID != nil
            // A device that authenticated but has no local data yet → pull
            // the whole Personal AI down before showing an empty chat.
            if state.needsCloudRestore, isAuthenticated, cloudSyncEnabled, hasCloudService {
                await restoreFromCloud()
            }
        }
        let id = await conversationStore.currentConversationID()
        conversationID = id
        messages = await conversationStore.loadConversation(id: id)
        memoryEnabled = await store.isMemoryEnabledGlobally()
        conversationDoNotRemember = await store.isConversationExcluded(id)
        triggerBackgroundSync()
    }

    /// Wire the signed-in identity through to the cloud engines. Called from
    /// the view layer on `authState.currentUser` changes. Signing out keeps
    /// **all** local data — it only stops uploading.
    func updateOwner(_ ownerID: String?) async {
        guard let cloud else { return }
        let previous = cloud.ownerBox.ownerID
        guard previous != ownerID else { return }
        cloud.ownerBox.ownerID = ownerID
        isAuthenticated = ownerID != nil

        if ownerID == nil {
            // Signed out — freeze sync, keep local data.
            return
        }
        // Newly signed in. If there is nothing local, mark for a restore on
        // the next open(); otherwise just resume syncing.
        let localMemories = await store.allMemories()
        let localMessages = await conversationStore.allMessages()
        let hasLocal = !localMemories.isEmpty || !localMessages.isEmpty
        await cloud.dataStore.updateSyncState { $0.needsCloudRestore = !hasLocal }
        if cloudSyncEnabled {
            if !hasLocal { await restoreFromCloud() }
            triggerBackgroundSync()
        }
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
        await conversationStore.setDoNotRemember(conversationID, value)
    }

    // MARK: - Phase 2 cloud controls

    func setCloudSyncEnabled(_ enabled: Bool) async {
        // Cannot enable sync with no cloud service wired.
        let effective = enabled && hasCloudService
        cloudSyncEnabled = effective
        guard let cloud else { return }
        await cloud.dataStore.updateSyncState { $0.cloudSyncEnabled = effective }
        if effective { triggerBackgroundSync() }
    }

    @discardableResult
    func syncNow() async -> SyncOutcome {
        guard let cloud else { return .skipped(reason: .noCloudService) }
        syncStatus = .running
        let outcome = await cloud.syncEngine.sync()
        let state = await cloud.dataStore.syncState()
        lastSyncedAt = state.lastSyncSucceededAt
        pendingSyncCount = state.pendingMutationCount
        switch outcome {
        case .completed:
            syncStatus = .succeeded(at: state.lastSyncSucceededAt ?? Date())
        case .skipped:
            syncStatus = .idle
        case .failedRetryable(let code), .failedFatal(let code):
            syncStatus = .failed(code: code)
        }
        return outcome
    }

    @discardableResult
    func restoreFromCloud() async -> PersonalAICloudRestoreCoordinator.Outcome {
        guard let cloud, let ownerID = cloud.ownerBox.ownerID else {
            return .init(source: .none, result: .failed)
        }
        let outcome = await cloud.restoreCoordinator.restore(ownerID: ownerID)
        if outcome.succeeded {
            // Reload the visible chat from the restored store.
            let id = await conversationStore.currentConversationID()
            conversationID = id
            messages = await conversationStore.loadConversation(id: id)
            memoryEnabled = await store.isMemoryEnabledGlobally()
        }
        return outcome
    }

    @discardableResult
    func backupNow() async -> PersonalAIBackupCoordinator.Outcome? {
        guard let cloud else { return nil }
        backupStatus = .running
        let outcome = await cloud.backupCoordinator.backup(tier: .daily)
        let state = await cloud.dataStore.syncState()
        lastBackupAt = state.lastBackupSucceededAt
        backupStatus = outcome.succeeded
            ? .succeeded(at: state.lastBackupSucceededAt ?? Date())
            : .failed(code: outcome.errorCode ?? "backup")
        return outcome
    }

    /// Write a portable export to a temp file and return its URL (for the
    /// share sheet). `nil` when the cloud stack isn't wired.
    func exportData(_ selection: ExportSelection) async -> URL? {
        guard let cloud else { return nil }
        let state = await cloud.dataStore.syncState()
        let bundle = await cloud.dataStore.exportBundle(selection: selection, bundleVersion: state.lastBackupVersion + 1)
        let name = "EvenAI-PersonalAI-\(selection.rawValue)-\(Int(Date().timeIntervalSince1970)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try PersonalDataExporter.write(bundle, to: url)
            return url
        } catch {
            DiagnosticTrace.log("PERSONAL_AI_EXPORT", "write failed: \(type(of: error))")
            return nil
        }
    }

    func importBackup(from url: URL, strategy: ImportStrategy = .merge) async -> Result<ImportResult, ImportError> {
        guard let cloud else { return .failure(.unreadable) }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        switch PersonalDataImporter.validate(data) {
        case .failure(let error):
            DiagnosticTrace.log("PERSONAL_AI_IMPORT", "rejected code=\(error.code)")
            return .failure(error)
        case .success(let bundle):
            let result = await cloud.dataStore.importBundle(bundle, strategy: strategy)
            if result.succeeded {
                let id = await conversationStore.currentConversationID()
                conversationID = id
                messages = await conversationStore.loadConversation(id: id)
                memoryEnabled = await store.isMemoryEnabledGlobally()
                triggerBackgroundSync()
            }
            return .success(result)
        }
    }

    /// §26 — remove server-side data, keep local (a distinct action from
    /// deleting the whole Personal AI account). No-op when no cloud service
    /// is wired (there is nothing server-side to delete).
    func deleteCloudData() async {
        guard hasCloudService, let cloud, let ownerID = cloud.ownerBox.ownerID else { return }
        try? await cloud.cloudDeleteAllData(ownerID: ownerID)
        await cloud.dataStore.updateSyncState {
            $0.cursor = nil
            $0.pendingMutationCount = 0
            $0.lastSyncSucceededAt = nil
        }
        cloudSyncEnabled = false
        await cloud.dataStore.updateSyncState { $0.cloudSyncEnabled = false }
    }

    /// §26 — true account deletion: server data (if any), local cache,
    /// conversations, style, and the local encryption key. Wipes local data
    /// **unconditionally** — even with no cloud wired.
    func deletePersonalAIAccount() async {
        if let cloud, let ownerID = cloud.ownerBox.ownerID {
            try? await cloud.cloudDeleteAllData(ownerID: ownerID)
        }
        await store.replaceAll(with: .empty)
        await conversationStore.wipe()
        try? cloud?.keyStore.destroy()
        messages = []
        conversationID = nil
        cloudSyncEnabled = false
        lastSyncedAt = nil
        lastBackupAt = nil
        pendingSyncCount = 0
    }

    // MARK: - Background sync trigger

    private func triggerBackgroundSync() {
        guard let cloud, cloudSyncEnabled, cloud.ownerBox.ownerID != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.syncNow()
            _ = await self.cloud?.backupCoordinator.runIfDue()
            await self.refreshCloudStatus()
        }
    }

    private func refreshCloudStatus() async {
        guard let cloud else { return }
        let state = await cloud.dataStore.syncState()
        lastSyncedAt = state.lastSyncSucceededAt
        lastBackupAt = state.lastBackupSucceededAt
        pendingSyncCount = state.pendingMutationCount
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

            // Success-path diagnostic — content-free: which provider actually
            // answered, whether memory was on, and the builder's own
            // content-free trace (already just section names / counts, e.g.
            // "retrieved=1/5", "knownProfile=1") — never user text, memory
            // content, or the assembled system prompt. Lets a physical-device
            // failure be distinguished as "nothing retrieved" vs "retrieved
            // but the provider still didn't use it" without reading personal
            // data.
            DiagnosticTrace.log(
                "PERSONAL_AI_CHAT",
                "success messageID=\(userMessage.id) provider=\(result.provider.rawValue) memoryEnabled=\(memoryEnabled ? "yes" : "no") \(context.buildTrace.joined(separator: " "))"
            )

            // 4. Passive extraction — only for eligible turns. This runs
            //    after the response is already visible (Phase 1 ordering),
            //    and cloud sync fires only after extraction, so neither ever
            //    delays the chat (§22/§24).
            if userMessage.eligibleForMemory {
                await extractAndMerge(userMessage: userMessage, assistantMessage: assistantMessage, conversationID: conversationID)
                await learnStyle(from: text)
            }
            triggerBackgroundSync()
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

    /// Version history for one memory (§7).
    func revisions(recordID: UUID) async -> [RecordRevision] { await store.revisions(recordID: recordID) }

    /// Restore a memory to a prior revision (§7 user-facing undo).
    @discardableResult
    func restoreMemoryRevision(_ revisionID: UUID) async -> Bool {
        guard let cloud else {
            // No cloud stack (tests) — do a direct restore from the store's log.
            let all = await store.allRevisions()
            guard let rev = all.first(where: { $0.id == revisionID }),
                  rev.recordKind == .memory,
                  let data = rev.previousPayloadJSON.data(using: .utf8),
                  var record = try? JSONDecoder.personalAI.decode(MemoryRecord.self, from: data)
            else { return false }
            record = record.touched()
            await store.upsert([record])
            return true
        }
        return await cloud.dataStore.restoreRevision(revisionID)
    }

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
