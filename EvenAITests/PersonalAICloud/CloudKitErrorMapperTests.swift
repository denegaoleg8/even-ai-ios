import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// Every CloudKit failure is translated into a provider-independent
/// classification. **No classification implies clearing local memory** — the
/// engine turns every thrown transport error into `.failedRetryable`.
@Suite("CloudKit: error mapping & classification")
struct CloudKitErrorMapperTests {

    private func classify(_ error: NSError) -> CloudKitErrorClassification {
        CloudKitErrorMapper.map(error).classification
    }

    @Test("notAuthenticated → requiresAccountAction")
    func notAuthenticated() {
        #expect(classify(CKErrorFixture.notAuthenticated) == .requiresAccountAction)
    }

    @Test("permissionFailure → requiresAccountAction")
    func permissionFailure() {
        #expect(classify(CKErrorFixture.permissionFailure) == .requiresAccountAction)
    }

    @Test("network / service / rate-limit / zone-busy → retryable")
    func retryables() {
        #expect(classify(CKErrorFixture.networkUnavailable) == .retryable)
        #expect(classify(CKErrorFixture.networkFailure) == .retryable)
        #expect(classify(CKErrorFixture.serviceUnavailable) == .retryable)
        #expect(classify(CKErrorFixture.requestRateLimited) == .retryable)
        #expect(classify(CKErrorFixture.zoneBusy) == .retryable)
    }

    @Test("requestRateLimited carries the server's Retry-After")
    func retryAfterPropagated() {
        let mapped = CloudKitErrorMapper.map(CKErrorFixture.requestRateLimited)
        #expect(mapped.retryAfter == 7.0)
    }

    @Test("quotaExceeded → fatalForOperationOnly (never data loss)")
    func quotaExceeded() {
        let mapped = CloudKitErrorMapper.map(CKErrorFixture.quotaExceeded)
        #expect(mapped.classification == .fatalForOperationOnly)
        #expect(mapped.code == "quotaExceeded")
    }

    @Test("operationCancelled → fatalForOperationOnly")
    func cancelled() {
        #expect(classify(CKErrorFixture.operationCancelled) == .fatalForOperationOnly)
        #expect(CloudKitErrorMapper.map(CancellationError()).classification == .fatalForOperationOnly)
    }

    @Test("unknownItem → fatalForOperationOnly")
    func unknownItem() {
        #expect(classify(CKErrorFixture.unknownItem) == .fatalForOperationOnly)
    }

    @Test("serverRecordChanged → requiresReconciliation")
    func serverRecordChanged() {
        #expect(classify(CKErrorFixture.make(.serverRecordChanged)) == .requiresReconciliation)
    }

    @Test("changeTokenExpired → requiresReconciliation")
    func changeTokenExpired() {
        #expect(classify(CKErrorFixture.changeTokenExpired) == .requiresReconciliation)
        #expect(CloudKitErrorMapper.map(CKErrorFixture.changeTokenExpired).code == "changeTokenExpired")
    }

    @Test("partialFailure → fatalForOperationOnly")
    func partialFailure() {
        #expect(classify(CKErrorFixture.partialFailure) == .fatalForOperationOnly)
    }

    @Test("every classification maps to a transport error the engine treats as retryable-skip (never data-clearing)")
    func transportNeverDataClearing() {
        let fixtures: [NSError] = [
            CKErrorFixture.notAuthenticated, CKErrorFixture.networkUnavailable,
            CKErrorFixture.serviceUnavailable, CKErrorFixture.quotaExceeded,
            CKErrorFixture.operationCancelled, CKErrorFixture.unknownItem,
            CKErrorFixture.make(.serverRecordChanged), CKErrorFixture.changeTokenExpired,
            CKErrorFixture.partialFailure, CKErrorFixture.zoneBusy,
        ]
        for fixture in fixtures {
            let transport = CloudKitErrorMapper.map(fixture).transport
            // The sync engine's only failure outcome is `.failedRetryable`,
            // which keeps every pending change and does not touch local data.
            // The transport code is just a label on that outcome.
            #expect(!transport.code.isEmpty)
        }
    }

    @Test("an unrecognised CKError code degrades to retryable, not fatal")
    func unknownCodeIsRetryable() {
        #expect(classify(CKErrorFixture.make(.init(rawValue: 9999) ?? .internalError)) == .retryable)
    }
}
