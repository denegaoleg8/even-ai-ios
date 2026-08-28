import Foundation

/// **TEST / DEVELOPMENT ONLY.** A thin transport over
/// `InMemoryPersonalCloudBackend` (whose "server" is RAM), plus injectable
/// failure/latency so tests can prove the sync engine's retry / "never lose
/// local data" guarantees.
///
/// It is **never** wired by `PersonalAIContainer.live` in a shipping build —
/// only by `PersonalAIContainer.simulated()`, which the app reaches solely
/// via the `-EvenAISimulatedCloud` launch argument in a `DEBUG` build. Data
/// pushed here does not survive an app relaunch. Phase 3 replaces this with a
/// real CloudKit / HTTP conformer; nothing above `PersonalCloudService`
/// changes.
struct MockPersonalCloudService: PersonalCloudService {

    /// What the next call should do. `.ok` by default.
    enum Behavior: Sendable, Equatable {
        case ok
        /// Throw a retryable network error before touching the backend.
        case offline
        /// Return a `SyncPullResult` whose `records` contain malformed JSON.
        case malformedPull
        /// Throw once, then succeed (exercises retry).
        case failOnce
        case unauthorized
    }

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _behavior: Behavior = .ok
        private var _pullCount = 0
        private var _pushCount = 0
        private var _failuresRemaining = 0

        var behavior: Behavior {
            get { lock.withLock { _behavior } }
            set { lock.withLock { _behavior = newValue; if newValue == .failOnce { _failuresRemaining = 1 } } }
        }
        var pullCount: Int { lock.withLock { _pullCount } }
        var pushCount: Int { lock.withLock { _pushCount } }
        func notePull() { lock.withLock { _pullCount += 1 } }
        func notePush() { lock.withLock { _pushCount += 1 } }
        func consumeFailOnce() -> Bool { lock.withLock { if _failuresRemaining > 0 { _failuresRemaining -= 1; return true }; return false } }
    }

    let backend: InMemoryPersonalCloudBackend
    let control: Control
    /// Builds a full bundle for `snapshot()` — supplied by whoever owns the
    /// backend's authoritative view (the test / restore coordinator).
    private let bundleBuilder: @Sendable (String, [SyncRecordEnvelope], String) async -> PersonalDataBundle

    init(
        backend: InMemoryPersonalCloudBackend = InMemoryPersonalCloudBackend(),
        control: Control = Control(),
        bundleBuilder: @escaping @Sendable (String, [SyncRecordEnvelope], String) async -> PersonalDataBundle = { _, envelopes, _ in
            PersonalBundleAssembler.assemble(from: envelopes, bundleVersion: 0)
        }
    ) {
        self.backend = backend
        self.control = control
        self.bundleBuilder = bundleBuilder
    }

    func pull(ownerID: String, since cursor: String?) async throws -> SyncPullResult {
        control.notePull()
        try preflight(forPull: true)
        let result = await backend.pull(ownerID: ownerID, since: cursor)
        if control.behavior == .malformedPull {
            return SyncPullResult(
                cursor: result.cursor,
                records: result.records.map { var e = $0; e.payloadJSON = "{ this is not json"; return e },
                hasMore: false
            )
        }
        return result
    }

    func push(_ request: SyncPushRequest) async throws -> SyncPushResult {
        control.notePush()
        try preflight(forPull: false)
        return await backend.push(request)
    }

    func snapshot(ownerID: String) async throws -> PersonalDataBundle {
        try preflight(forPull: true)
        let (cursor, envelopes) = await backend.snapshotEnvelopes(ownerID: ownerID)
        return await bundleBuilder(ownerID, envelopes, cursor)
    }

    func deleteAllData(ownerID: String) async throws {
        try preflight(forPull: false)
        await backend.deleteAllData(ownerID: ownerID)
    }

    private func preflight(forPull: Bool) throws {
        switch control.behavior {
        case .ok, .malformedPull:
            return
        case .offline:
            throw PersonalCloudTransportError.offline
        case .unauthorized:
            throw PersonalCloudTransportError.unauthorized
        case .failOnce:
            if control.consumeFailOnce() { throw PersonalCloudTransportError.offline }
        }
    }
}

enum PersonalCloudTransportError: Error, Equatable, Sendable {
    case offline
    case unauthorized
    case server(Int)
    case decode

    var code: String {
        switch self {
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .server(let s): return "server\(s)"
        case .decode: return "decode"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .offline, .server: return true
        case .unauthorized, .decode: return false
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
