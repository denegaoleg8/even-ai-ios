import Foundation

/// Decides what to do with a freshly extracted `MemoryCandidate` relative to
/// memory that already exists: insert it, treat it as a duplicate, or let it
/// supersede a now-contradicted record. **Never leaves two equally-active
/// contradictory facts**, and always carries provenance forward.
struct MemoryMerger: Sendable {

    /// Known "value tokens" whose disagreement between two otherwise-similar
    /// statements is strong evidence of a contradiction (a rescheduled
    /// launch, a changed decision).
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "q1", "q2", "q3", "q4",
    ]

    init() {}

    func reconcile(candidate: MemoryCandidate, against existing: [MemoryRecord], now: Date = .now) -> MergeDecision {
        let content = candidate.record.canonicalContent

        if let finding = SecretDetector.firstFinding(in: content) {
            return .reject(reason: "looks like a credential (\(finding.kind))")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .reject(reason: "too short to be meaningful") }

        let active = existing.filter { $0.status == .active && $0.deletedAt == nil }

        // 1. Exact / near-exact duplicate in the same category → refresh it.
        if let dup = active.first(where: { $0.category == candidate.record.category
            && TextSimilarity.looksLikeDuplicate($0.canonicalContent, content) }) {
            var refreshed = dup.touched(now: now)
            refreshed.lastUsedAt = now
            refreshed.confidence = max(dup.confidence, candidate.record.confidence)
            refreshed.importance = max(dup.importance, candidate.record.importance)
            refreshed.userConfirmed = dup.userConfirmed || candidate.record.userConfirmed
            refreshed.sourceConversationIDs = Array(Set(dup.sourceConversationIDs + candidate.record.sourceConversationIDs))
            refreshed.sourceMessageIDs = Array(Set(dup.sourceMessageIDs + candidate.record.sourceMessageIDs))
            refreshed.entities = Array(Set(dup.entities + candidate.record.entities))
            return .duplicate(existingID: dup.id, refreshed: refreshed)
        }

        // 2. Same category, same subject, disagreeing detail → supersede.
        if let contradicted = active.first(where: { isContradiction(existing: $0, candidateContent: content, category: candidate.record.category) }) {
            var newRecord = candidate.record
            newRecord.supersedesID = contradicted.id
            newRecord.importance = max(newRecord.importance, contradicted.importance)
            newRecord.confidence = max(newRecord.confidence, contradicted.confidence * 0.9)
            newRecord.sourceConversationIDs = Array(Set(newRecord.sourceConversationIDs + contradicted.sourceConversationIDs))
            newRecord.sourceMessageIDs = Array(Set(newRecord.sourceMessageIDs + contradicted.sourceMessageIDs))
            newRecord.entities = Array(Set(newRecord.entities + contradicted.entities))
            return .supersede(supersededID: contradicted.id, newRecord: newRecord)
        }

        // 3. One statement strictly contains the other (extra detail) → merge
        //    into the existing record, keeping the richer text.
        if let superset = active.first(where: { $0.category == candidate.record.category
            && subsumes(longer: content, shorter: $0.canonicalContent) }) {
            var merged = superset.touched(now: now)
            merged.canonicalContent = content
            merged.lastUsedAt = now
            merged.confidence = max(superset.confidence, candidate.record.confidence)
            merged.userConfirmed = superset.userConfirmed || candidate.record.userConfirmed
            merged.sourceConversationIDs = Array(Set(superset.sourceConversationIDs + candidate.record.sourceConversationIDs))
            merged.sourceMessageIDs = Array(Set(superset.sourceMessageIDs + candidate.record.sourceMessageIDs))
            merged.entities = Array(Set(superset.entities + candidate.record.entities))
            return .mergeInto(existingID: superset.id, merged: merged)
        }

        return .create(candidate.record)
    }

    // MARK: - Contradiction detection

    private func isContradiction(existing: MemoryRecord, candidateContent: String, category: MemoryCategory) -> Bool {
        guard existing.category == category else { return false }
        // Only categories where a single canonical value makes sense.
        guard [.projects, .profile, .preferences, .knowledge, .workingContext].contains(category) else { return false }

        let a = existing.canonicalContent
        let b = candidateContent
        if TextSimilarity.looksLikeDuplicate(a, b) { return false }

        let sharedSubject = TextSimilarity.coverage(needle: a, haystack: b) >= 0.4
            && TextSimilarity.coverage(needle: b, haystack: a) >= 0.4
        let sharesEntity = !TextSimilarity.tokenSet(a).isDisjoint(with: TextSimilarity.tokenSet(b))
        guard sharedSubject || (sharesEntity && sharedEntitySubject(a, b)) else { return false }

        // A disagreeing "value token" (different month/quarter, or a
        // different number) clinches it.
        let ta = TextSimilarity.tokenSet(a)
        let tb = TextSimilarity.tokenSet(b)
        let monthsA = ta.intersection(Self.months)
        let monthsB = tb.intersection(Self.months)
        if !monthsA.isEmpty, !monthsB.isEmpty, monthsA != monthsB { return true }

        let numsA = numbers(in: a)
        let numsB = numbers(in: b)
        if !numsA.isEmpty, !numsB.isEmpty, numsA != numsB { return true }

        // No explicit value token, but the statements are strongly about the
        // same thing yet not duplicates → still an update.
        return sharedSubject
            && TextSimilarity.coverage(needle: a, haystack: b) < 0.8
            && TextSimilarity.coverage(needle: b, haystack: a) < 0.8
            && TextSimilarity.jaccard(a, b) >= 0.34
    }

    private func sharedEntitySubject(_ a: String, _ b: String) -> Bool {
        let common = TextSimilarity.tokenSet(a).intersection(TextSimilarity.tokenSet(b))
        return common.contains { $0.count >= 4 }
    }

    private func numbers(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .filter { !$0.isEmpty })
    }

    private func subsumes(longer: String, shorter: String) -> Bool {
        let l = TextSimilarity.tokenSet(longer)
        let s = TextSimilarity.tokenSet(shorter)
        guard s.count >= 2, l.count > s.count else { return false }
        return s.isSubset(of: l)
    }
}
