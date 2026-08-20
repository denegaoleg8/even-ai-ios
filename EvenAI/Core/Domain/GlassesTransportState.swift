import Foundation

/// Vendor-neutral connection lifecycle for a `GlassesTransport`. Deliberately
/// small — this is the only shape any `Features/` code should ever need to
/// know about a glasses connection; anything transport-specific (device
/// lists, RSSI, firmware info, ...) stays behind the transport's own
/// implementation and is never exposed through this enum.
enum GlassesTransportState: Sendable, Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case failed(String)
}
