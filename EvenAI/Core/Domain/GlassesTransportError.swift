import Foundation

enum GlassesTransportError: Error, LocalizedError, Sendable {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Glasses are not connected."
        }
    }
}
