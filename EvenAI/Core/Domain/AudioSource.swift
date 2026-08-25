import Foundation

/// Which physical microphone Live Translation captures from. Confirmed
/// against the vendored `MentraBluetoothSDK` source (not guessed):
/// `MentraBluetoothSDK.setMicState(enabled:useGlassesMic:...)` already
/// takes a `useGlassesMic` flag, and `useGlassesMic == false` routes
/// through the SDK's own internal `PhoneMic` (`AVAudioEngine`-based,
/// converts to the exact same 16kHz/16-bit/mono PCM shape G2's own mic
/// produces) — both paths dispatch through the SAME `didReceiveMicPcm`
/// bridge event, so `MentraGlassesTransport.microphonePCMUpdates()` and
/// everything downstream of it (transcription, streaming translation)
/// work unchanged regardless of which source is active. Mirrors what the
/// official Even Translate app exposes (G2 mic vs. phone mic), now
/// confirmed reachable through this SDK too — not a guess or a
/// workaround.
enum AudioSource: String, CaseIterable, Codable, Sendable {
    case g2Mic
    case phoneMic

    var displayLabel: String {
        switch self {
        case .g2Mic: "G2 Mic"
        case .phoneMic: "Phone Mic"
        }
    }
}
