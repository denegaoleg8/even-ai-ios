import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// iCloud account safety: A → signed out → B must never merge identities,
/// never auto-upload A's data into B, never auto-delete local data, and expose
/// a reconciliation-required state. Switching back to A resumes safely.
@MainActor
@Suite("CloudKit: iCloud account switch safety")
struct CloudKitAccountSwitchTests {

    @Test("1 — first CloudKit identity binds to the current iCloud account")
    func firstBind() async {
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A")
        await h.memoryStore.upsert([MemoryRecord.fixture("first fact")])
        let outcome = await h.syncEngine.sync()
        #expect(outcome.isSuccess)

        let binding = await h.stateStore.load().binding
        #expect(binding?.personalAIUserID == "user-1")
        #expect(binding?.ckUserRecordName == "icloud-A")
    }

    @Test("2 — the same identity resumes without re-binding")
    func sameIdentityResumes() async {
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A")
        await h.memoryStore.upsert([MemoryRecord.fixture("fact one")])
        _ = await h.syncEngine.sync()
        let boundAt = await h.stateStore.load().binding?.boundAt

        await h.memoryStore.upsert([MemoryRecord.fixture("fact two")])
        let outcome = await h.syncEngine.sync()
        #expect(outcome.isSuccess)
        #expect(await h.stateStore.load().binding?.boundAt == boundAt) // unchanged
    }

    @Test("3 — A signed out: sync frozen, local data fully retained")
    func signedOutRetainsData() async {
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A")
        await h.memoryStore.upsert([MemoryRecord.fixture("synced fact")])
        _ = await h.syncEngine.sync()

        h.database.accountStatusValue = .noAccount
        await h.memoryStore.upsert([MemoryRecord.fixture("offline fact")])
        let outcome = await h.syncEngine.sync()

        if case .failedRetryable = outcome {} else { Issue.record("expected .failedRetryable, got \(outcome)") }
        #expect((await h.memoryStore.allMemories()).count == 2)

        let state = await h.service.currentAccountState()
        #expect(state == .noAccount)
        #expect(state.freezesWrites)
    }

    @Test("4/5/6/7 — A → B detected; A's data not uploaded to B; no merge; B not canonical")
    func switchToBIsSafe() async {
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A")
        await h.memoryStore.upsert([MemoryRecord.fixture("A private fact one")])
        await h.memoryStore.upsert([MemoryRecord.fixture("A private fact two")])
        _ = await h.syncEngine.sync()
        #expect(h.database.totalRecordCount(user: "icloud-A") >= 2)

        // Sign into a different iCloud account.
        h.database.simulateICloudAccountSwitch(to: "icloud-B")
        await h.memoryStore.upsert([MemoryRecord.fixture("added while on B")])
        let outcome = await h.syncEngine.sync()

        // Detected + frozen.
        if case .failedRetryable = outcome {} else { Issue.record("expected .failedRetryable, got \(outcome)") }
        let state = await h.service.currentAccountState()
        #expect(state.needsUserReconciliation)

        // A's data was NOT uploaded into B's database.
        #expect(h.database.totalRecordCount(user: "icloud-B") == 0)
        // No auto-merge: local is untouched, still holds all three.
        #expect((await h.memoryStore.allMemories()).count == 3)
        // B did NOT silently become the canonical owner.
        let binding = await h.stateStore.load().binding
        #expect(binding?.ckUserRecordName == "icloud-A")
        #expect(h.ownerBox.ownerID == "user-1")
    }

    @Test("8/9 — B → A resumes safely after the binding matches again; cache intact throughout")
    func switchBackResumes() async {
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A")
        await h.memoryStore.upsert([MemoryRecord.fixture("fact from A")])
        _ = await h.syncEngine.sync()

        h.database.simulateICloudAccountSwitch(to: "icloud-B")
        await h.memoryStore.upsert([MemoryRecord.fixture("fact added during mismatch")])
        _ = await h.syncEngine.sync()
        #expect((await h.memoryStore.allMemories()).count == 2) // cache intact during mismatch

        // Back to A.
        h.database.simulateICloudAccountSwitch(to: "icloud-A")
        let outcome = await h.syncEngine.sync()
        #expect(outcome.isSuccess)
        #expect((await h.memoryStore.allMemories()).count == 2) // cache intact after resume
        #expect(h.database.totalRecordCount(user: "icloud-A") >= 2) // the queued fact reached A
        #expect(h.database.totalRecordCount(user: "icloud-B") == 0) // B never got anything
    }

    @Test("10 — reconciliation-required state is observable without a sync attempt")
    func reconciliationStateObservable() async {
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A")
        await h.memoryStore.upsert([MemoryRecord.fixture("x")])
        _ = await h.syncEngine.sync()

        h.database.simulateICloudAccountSwitch(to: "icloud-B")
        let state = await h.service.currentAccountState()
        guard case .reconciliationRequired(let reason) = state else {
            Issue.record("expected .reconciliationRequired, got \(state)"); return
        }
        #expect(reason.personalAIUserID == "user-1")
        #expect(reason.expectedICloudUser == "icloud-A")
        #expect(reason.actualICloudUser == "icloud-B")
    }

    @Test("pure evaluator: every account status resolves deterministically")
    func evaluatorMatrix() {
        let binding = CloudKitAccountBinding(personalAIUserID: "u", ckUserRecordName: "ic-A", boundAt: .now)
        #expect(CloudKitAccountEvaluator.evaluate(status: .noAccount, currentICloudUserRecordName: nil, binding: binding, personalAIUserID: "u") == .noAccount)
        #expect(CloudKitAccountEvaluator.evaluate(status: .restricted, currentICloudUserRecordName: nil, binding: binding, personalAIUserID: "u") == .restricted)
        #expect(CloudKitAccountEvaluator.evaluate(status: .couldNotDetermine, currentICloudUserRecordName: nil, binding: binding, personalAIUserID: "u") == .indeterminate)
        #expect(CloudKitAccountEvaluator.evaluate(status: .available, currentICloudUserRecordName: "ic-A", binding: nil, personalAIUserID: "u") == .unbound)
        #expect(CloudKitAccountEvaluator.evaluate(status: .available, currentICloudUserRecordName: "ic-A", binding: binding, personalAIUserID: "u") == .bound)
        let mismatch = CloudKitAccountEvaluator.evaluate(status: .available, currentICloudUserRecordName: "ic-B", binding: binding, personalAIUserID: "u")
        #expect(mismatch.needsUserReconciliation)
        #expect(!mismatch.allowsSync)
    }
}
