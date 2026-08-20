import Foundation

/// `LIVE_TRACE` error/anomaly visibility for Live Translation — what's left
/// after the original, much larger diagnostic pass (which included a
/// `DICTATE_TRACE` prefix, removed along with the Dictate-to-Chat feature
/// itself, and a great deal of verbose entry/exit/"first callback" tracing
/// in `GlassesSpeechTranscriber`, `LiveTranslationService`, and
/// `MentraGlassesTransport`, removed once it had served its purpose for
/// that investigation). The remaining call sites are deliberately kept:
/// each one is a failure or anomaly (a translation/`sendText` error, a PCM
/// format mismatch against what `GlassesSpeechTranscriber` assumes, a
/// malformed PCM chunk silently dropped) that has no other visibility
/// anywhere in the app — removing these would mean swallowing them
/// entirely, not just trimming noise.
///
/// Uses `print`, not `AppLogger`/`os.Logger` — unlike `AppLogger`'s
/// categories, this was never wired up as permanent product logging
/// infrastructure; it's a lightweight stand-in that happens to still be
/// the only place these specific failures surface at all.
enum DiagnosticTrace {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSSS"
        return formatter
    }()

    static func log(_ prefix: String, _ message: String) {
        let timestamp = formatter.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "bg:\(Thread.current)"
        print("\(prefix) [\(timestamp)] [\(thread)] \(message)")
    }
}
