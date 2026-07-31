import Foundation

/// Wire-format DTOs for the Even AI auth API. `AccountDTO`'s field names
/// already match `User`'s 1:1 (the backend's `toPublicAccount` emits
/// camelCase `displayName`, not `display_name`) — kept as a separate
/// type from `User` anyway, for the same reason `ChatDTO`/`MessageDTO`
/// stay separate from `Chat`/`Message`: the wire format and the domain
/// model are different concerns, even when they happen to agree today.

struct AccountDTO: Decodable {
    let id: UUID
    let email: String?
    let displayName: String?

    func toDomain() -> User {
        User(id: id, email: email, displayName: displayName)
    }
}

struct DeviceAuthResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let account: AccountDTO
}

struct LoginResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let account: AccountDTO
    let mergeAvailableFrom: UUID?
    /// Short-lived proof, minted by this exact login call, that the
    /// caller is who `mergeAvailableFrom` was actually offered to — see
    /// the backend's `signMergeToken`. `nil` whenever `mergeAvailableFrom`
    /// is, and safe to omit later (merging past its ~5 minute window
    /// falls back to the backend's original ownership check).
    let mergeToken: String?
}

struct SignupResponseDTO: Decodable {
    let account: AccountDTO
}

struct MergeResponseDTO: Decodable {
    let mergedChatCount: Int
}
