import CloudKit

/// Infrastructure identity binding.
///
/// The canonical, portable Personal AI identity is **`PersonalAIUserID`** (the
/// EvenAI account id, the value already flowing through `ownerBox.ownerID`).
/// It is what lands in `ownerID` on every record, what
/// `SyncableStyleProfile.stableID` derives from, and what a future backup /
/// Postgres adapter keys on.
///
/// This record pins which **iCloud account** a given `PersonalAIUserID` has
/// been syncing with. The CloudKit user record name lives only here and never
/// becomes canonical — so an iCloud account switch is detected as an
/// infrastructure event, not mistaken for a user switch, and a later migration
/// to another provider needs no identity remap.
struct CloudKitAccountBinding: Codable, Hashable, Sendable {
    var personalAIUserID: String
    var ckUserRecordName: String
    var boundAt: Date
}

/// The account situation the adapter is in. **Only `.bound` allows sync.**
/// Every other state freezes cloud writes and keeps all local data.
enum CloudKitAccountState: Equatable, Sendable {

    /// Signed out of iCloud. Freeze, keep data.
    case noAccount
    /// Restricted (MDM / parental controls). Freeze, keep data.
    case restricted
    /// Status could not be determined / temporarily unavailable. Freeze, retry.
    case indeterminate
    /// iCloud available, no binding yet — safe to bind to the current account.
    case unbound
    /// iCloud available and matches the binding — sync allowed.
    case bound
    /// iCloud available but a **different** account than the binding.
    /// Freeze, keep data, surface to the user, never auto-merge / auto-upload /
    /// auto-delete / silently rebind.
    case reconciliationRequired(Reason)

    struct Reason: Equatable, Sendable {
        var personalAIUserID: String
        var expectedICloudUser: String
        var actualICloudUser: String
    }

    var allowsSync: Bool {
        if case .bound = self { return true }
        return false
    }

    var freezesWrites: Bool { !allowsSync }

    var needsUserReconciliation: Bool {
        if case .reconciliationRequired = self { return true }
        return false
    }
}

/// Pure decision function — no side effects, fully deterministic.
enum CloudKitAccountEvaluator {

    static func evaluate(
        status: CKAccountStatus,
        currentICloudUserRecordName: String?,
        binding: CloudKitAccountBinding?,
        personalAIUserID: String?
    ) -> CloudKitAccountState {
        switch status {
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            return .indeterminate
        case .available:
            guard let personalAIUserID, !personalAIUserID.isEmpty,
                  let currentICloudUserRecordName, !currentICloudUserRecordName.isEmpty
            else { return .indeterminate }

            guard let binding else { return .unbound }

            if binding.personalAIUserID == personalAIUserID,
               binding.ckUserRecordName == currentICloudUserRecordName {
                return .bound
            }
            return .reconciliationRequired(.init(
                personalAIUserID: personalAIUserID,
                expectedICloudUser: binding.ckUserRecordName,
                actualICloudUser: currentICloudUserRecordName
            ))
        @unknown default:
            return .indeterminate
        }
    }
}
