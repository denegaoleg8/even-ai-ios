import CloudKit

/// How a CloudKit failure affects the current operation and what the app
/// should do about it.
enum CloudKitErrorClassification: String, Sendable, Equatable {
    /// Transient — retry the same operation later. No user action.
    case retryable
    /// The iCloud account needs attention (signed out, restricted, permission).
    /// Freeze sync; keep all local data.
    case requiresAccountAction
    /// The adapter must reconcile before proceeding (stale record, expired
    /// change token, or a different iCloud account). Handled inline where
    /// possible; an account mismatch is surfaced to the user.
    case requiresReconciliation
    /// This operation cannot complete now (quota, cancelled, missing item),
    /// but nothing is wrong with local data and a later operation may succeed.
    case fatalForOperationOnly
}

/// A CloudKit error translated into a provider-independent shape. Carries both
/// the fine-grained classification (for adapter logic / diagnostics / future
/// UI) and a `PersonalCloudTransportError` for the `PersonalCloudService`
/// throw contract the sync engine already understands.
///
/// **No classification ever implies clearing local authoritative memory.** The
/// sync engine turns every thrown transport error into `.failedRetryable`,
/// which keeps every pending change queued and the cursor untouched.
struct CloudKitMappedError: Error, Equatable, Sendable {
    var code: String
    var classification: CloudKitErrorClassification
    var retryAfter: TimeInterval?
    var ckCode: Int?

    var transport: PersonalCloudTransportError {
        switch classification {
        case .requiresAccountAction, .requiresReconciliation:
            return .unauthorized
        case .retryable:
            return .offline
        case .fatalForOperationOnly:
            switch code {
            case "quotaExceeded": return .server(507)
            case "operationCancelled": return .offline
            default: return .offline
            }
        }
    }
}

enum CloudKitErrorMapper {

    static func map(_ error: Error) -> CloudKitMappedError {
        guard let ckError = error as? CKError else {
            if error is CancellationError {
                return CloudKitMappedError(code: "operationCancelled", classification: .fatalForOperationOnly)
            }
            return CloudKitMappedError(code: "unknown", classification: .retryable)
        }

        let retryAfter = (ckError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        let raw = ckError.code.rawValue

        switch ckError.code {
        case .notAuthenticated:
            return .init(code: "notAuthenticated", classification: .requiresAccountAction, retryAfter: retryAfter, ckCode: raw)
        case .permissionFailure:
            return .init(code: "permissionFailure", classification: .requiresAccountAction, retryAfter: retryAfter, ckCode: raw)
        case .managedAccountRestricted:
            return .init(code: "managedAccountRestricted", classification: .requiresAccountAction, retryAfter: retryAfter, ckCode: raw)

        case .networkUnavailable, .networkFailure:
            return .init(code: "networkUnavailable", classification: .retryable, retryAfter: retryAfter, ckCode: raw)
        case .serviceUnavailable:
            return .init(code: "serviceUnavailable", classification: .retryable, retryAfter: retryAfter ?? 3, ckCode: raw)
        case .requestRateLimited:
            return .init(code: "requestRateLimited", classification: .retryable, retryAfter: retryAfter ?? 5, ckCode: raw)
        case .zoneBusy:
            return .init(code: "zoneBusy", classification: .retryable, retryAfter: retryAfter ?? 3, ckCode: raw)
        case .serverResponseLost, .internalError:
            return .init(code: "serverTransient", classification: .retryable, retryAfter: retryAfter, ckCode: raw)

        case .quotaExceeded:
            return .init(code: "quotaExceeded", classification: .fatalForOperationOnly, retryAfter: retryAfter, ckCode: raw)
        case .operationCancelled:
            return .init(code: "operationCancelled", classification: .fatalForOperationOnly, ckCode: raw)
        case .unknownItem:
            return .init(code: "unknownItem", classification: .fatalForOperationOnly, ckCode: raw)
        case .limitExceeded:
            return .init(code: "limitExceeded", classification: .fatalForOperationOnly, ckCode: raw)
        case .batchRequestFailed:
            return .init(code: "batchRequestFailed", classification: .retryable, ckCode: raw)

        case .serverRecordChanged:
            return .init(code: "serverRecordChanged", classification: .requiresReconciliation, ckCode: raw)
        case .changeTokenExpired:
            return .init(code: "changeTokenExpired", classification: .requiresReconciliation, ckCode: raw)
        case .zoneNotFound, .userDeletedZone:
            return .init(code: "zoneNotFound", classification: .fatalForOperationOnly, ckCode: raw)

        case .partialFailure:
            return .init(code: "partialFailure", classification: .fatalForOperationOnly, ckCode: raw)

        default:
            return .init(code: "ck\(raw)", classification: .retryable, retryAfter: retryAfter, ckCode: raw)
        }
    }

    /// Extract the per-record errors from a `.partialFailure`, keyed by record
    /// name, so `push` can classify each record independently.
    static func partialErrors(_ error: CKError) -> [String: CloudKitMappedError] {
        guard error.code == .partialFailure,
              let byID = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error]
        else { return [:] }
        var result: [String: CloudKitMappedError] = [:]
        for (key, value) in byID {
            let name = (key as? CKRecord.ID)?.recordName ?? "\(key)"
            result[name] = map(value)
        }
        return result
    }
}
