import Foundation

/// Applies the memory-affecting commands found in a user message —
/// immediately and deterministically. This is the "explicit current
/// instruction" tier of the priority ladder: it runs before generation, so a
/// command in *this* message always takes effect for *this* turn.
///
/// Separate from `HeuristicMemoryExtractor` (passive durable-fact capture)
/// and testable on its own against any `PersonalMemoryStore`.
struct MemoryCommandProcessor: Sendable {

    private let interpreter: CommandInterpreter
    private let merger: MemoryMerger
    private let styleLearner: StyleProfileLearner

    init(
        interpreter: CommandInterpreter = CommandInterpreter(),
        merger: MemoryMerger = MemoryMerger(),
        styleLearner: StyleProfileLearner = StyleProfileLearner()
    ) {
        self.interpreter = interpreter
        self.merger = merger
        self.styleLearner = styleLearner
    }

    struct Outcome: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case remembered(MemoryCategory)
            case ruleAdded
            case forgotten(count: Int)
            case styleUpdated
            case rejectedSecret
            case noMatchToForget
        }
        var kind: Kind
        var summary: String
        /// A transient rule representing this-message instruction, for the
        /// context builder to inject at `.explicitCurrentInstruction`.
        var transientRule: Rule?
    }

    /// Interprets `message` and applies every command to `store`. Returns
    /// one `Outcome` per applied command (empty if the message contained
    /// none).
    @discardableResult
    func process(
        message: String,
        conversationID: UUID?,
        messageID: UUID?,
        store: any PersonalMemoryStore,
        now: Date = .now
    ) async -> [Outcome] {
        let commands = interpreter.interpret(message)
        guard !commands.isEmpty else { return [] }

        let convProvenance = conversationID.map { [$0] } ?? []
        let msgProvenance = messageID.map { [$0] } ?? []
        var outcomes: [Outcome] = []

        for command in commands {
            switch command {
            case let .remember(content, category):
                if SecretDetector.containsSecret(content) {
                    outcomes.append(Outcome(kind: .rejectedSecret, summary: "That looked like a credential, so I didn't store it.", transientRule: nil))
                    continue
                }
                let record = MemoryRecord(
                    category: category,
                    canonicalContent: HeuristicMemoryExtractor.canonicalize(content),
                    entities: HeuristicMemoryExtractor.entities(in: content),
                    createdAt: now, updatedAt: now,
                    confidence: 0.92, importance: 0.72, userConfirmed: true,
                    sourceConversationIDs: convProvenance, sourceMessageIDs: msgProvenance
                )
                await applyMerge(MemoryCandidate(record: record, rationale: "explicit remember command", originatingCommand: command, salience: 0.95), to: store, now: now)
                outcomes.append(Outcome(kind: .remembered(category), summary: "Got it — I'll remember that.", transientRule: nil))

            case let .addRule(text, scope):
                if SecretDetector.containsSecret(text) {
                    outcomes.append(Outcome(kind: .rejectedSecret, summary: "That looked like a credential, so I didn't store it.", transientRule: nil))
                    continue
                }
                let existing = await store.allRules()
                if let dup = existing.first(where: { TextSimilarity.looksLikeDuplicate($0.text, text) }) {
                    var refreshed = dup.touched(now: now)
                    refreshed.enabled = true
                    refreshed.text = text
                    refreshed.sourceConversationIDs = Array(Set(dup.sourceConversationIDs + convProvenance))
                    await store.upsertRule(refreshed)
                } else {
                    await store.upsertRule(Rule(
                        text: text, createdAt: now, updatedAt: now,
                        priority: .activeRule, scope: scope, source: .explicitCommand,
                        sourceConversationIDs: convProvenance, sourceMessageIDs: msgProvenance
                    ))
                }
                outcomes.append(Outcome(kind: .ruleAdded, summary: "Rule added.", transientRule: nil))

            case let .forget(query):
                let all = await store.allMemories()
                let matches = Self.forgetMatches(query: query, in: all)
                if matches.isEmpty {
                    outcomes.append(Outcome(kind: .noMatchToForget, summary: "I couldn't find a memory matching that.", transientRule: nil))
                } else {
                    for match in matches {
                        await store.setMemoryStatus(id: match.id, status: .archived)
                        await store.setMemoryEnabled(id: match.id, enabled: false)
                    }
                    // Also disable a matching rule, if the user meant a rule.
                    let rules = await store.allRules()
                    for rule in rules where TextSimilarity.coverage(needle: query, haystack: rule.text) >= 0.6 {
                        await store.setRuleEnabled(id: rule.id, enabled: false)
                    }
                    outcomes.append(Outcome(kind: .forgotten(count: matches.count), summary: "Forgotten.", transientRule: nil))
                }

            case let .setStyle(directive):
                let profile = await store.styleProfile()
                let updated = styleLearner.applyingDirective(directive, to: profile, now: now)
                await store.updateStyleProfile(updated)
                // Also record it as a visible STYLE memory / rule.
                let ruleText = HeuristicMemoryExtractor.canonicalize(directive)
                let rules = await store.allRules()
                if !rules.contains(where: { TextSimilarity.looksLikeDuplicate($0.text, ruleText) }) {
                    await store.upsertRule(Rule(
                        text: ruleText, createdAt: now, updatedAt: now,
                        priority: .activeRule, scope: .global, source: .explicitCommand,
                        sourceConversationIDs: convProvenance, sourceMessageIDs: msgProvenance
                    ))
                }
                outcomes.append(Outcome(kind: .styleUpdated, summary: "Style updated.", transientRule: nil))
            }
        }
        return outcomes
    }

    // MARK: - Helpers

    private func applyMerge(_ candidate: MemoryCandidate, to store: any PersonalMemoryStore, now: Date) async {
        let existing = await store.allMemories()
        switch merger.reconcile(candidate: candidate, against: existing, now: now) {
        case .create(let record):
            await store.upsert([record])
        case .duplicate(_, let refreshed):
            await store.upsert([refreshed])
        case .mergeInto(_, let merged):
            await store.upsert([merged])
        case .supersede(let supersededID, let newRecord):
            await store.upsert([newRecord])
            if let old = existing.first(where: { $0.id == supersededID }) {
                // `.touched()` so `revision` / `updatedAt` / `syncState`
                // move too — a future cloud sync must see the old record
                // change, not just the new record's arrival.
                var updated = old.touched(now: now)
                updated.status = .superseded
                updated.supersededByID = newRecord.id
                await store.upsert([updated])
            } else {
                await store.setMemoryStatus(id: supersededID, status: .superseded)
            }
        case .reject:
            break
        }
    }

    static func forgetMatches(query: String, in records: [MemoryRecord]) -> [MemoryRecord] {
        let candidates = records.filter { $0.status == .active && $0.deletedAt == nil }
        let scored = candidates
            .map { (record: $0, score: max(
                TextSimilarity.coverage(needle: query, haystack: $0.canonicalContent),
                TextSimilarity.coverage(needle: query, haystack: $0.entities.joined(separator: " "))
            )) }
            .filter { $0.score >= 0.5 }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return [] }
        // Archive the clear best match, plus any near-ties (same fact stated twice).
        return scored.filter { $0.score >= best.score - 0.15 }.map { $0.record }
    }
}
