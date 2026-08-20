import SwiftUI

/// How `Features/Glasses` gets its `GlassesTransport` — through the
/// environment, mirroring `EnvironmentValues+ChatService.swift`'s pattern
/// (the Dependency Rule in `ARCHITECTURE.md`: `Features` may depend on
/// `Infrastructure` only via DI, never a concrete `Infrastructure` type,
/// and never `App/DI` itself).
private struct GlassesTransportKey: EnvironmentKey {
    // MockGlassesTransport, not AppContainer.live: safe for any preview or
    // test that renders these views without bothering to wire this up —
    // EvenAIApp is the only place that overrides it with the real thing.
    static let defaultValue: GlassesTransport = MockGlassesTransport()
}

extension EnvironmentValues {
    var glassesTransport: GlassesTransport {
        get { self[GlassesTransportKey.self] }
        set { self[GlassesTransportKey.self] = newValue }
    }
}
