import Foundation

/// Result of a sign-in. `mergeAvailableFrom` is set when the signing-in
/// device already had its own anonymous account with local chats — the
/// caller can offer to merge that account's data into the one just
/// signed into (see `AuthServicing.mergeAccount`). Not set by sign-up,
/// since claiming a device's own account never leaves anything to merge.
struct AuthResult: Sendable {
    let user: User
    let mergeAvailableFrom: User.ID?
}
