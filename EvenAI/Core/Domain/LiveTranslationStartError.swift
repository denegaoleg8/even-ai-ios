import Foundation

/// Why a Live Translation `start()` attempt failed — classified so the
/// user is told the TRUTH about what went wrong, never a blanket "check
/// your G2 connection" for a failure that had nothing to do with G2 at
/// all.
///
/// This exists to fix a real regression: `LiveTranslationService.start()`
/// used to funnel every failure — a genuine G2/microphone problem, a
/// failed session-credential recovery, an unreachable backend, or a
/// failed STT WebSocket handshake — into the exact same "Couldn't start
/// Live Translation. Check your G2 connection and try again." message.
/// Once session-credential recovery started happening synchronously
/// during `start()` (see `URLSessionRealtimeTranscriptionSocket
/// .connect()`), an auth/network failure there surfaced through that
/// same generic G2-labeled catch block — a user with a perfectly healthy
/// G2 connection would be told to go check it, for a problem that had
/// nothing to do with G2 at all.
enum LiveTranslationStartError: Error, Equatable {
    /// G2 itself — BLE connection/pairing, or the transport's own
    /// `setMicrophoneEnabled` rejecting the request because G2 isn't
    /// connected. Only ever produced when `AudioSource.g2Mic` is
    /// selected — see `microphoneUnavailable` for the phone-mic
    /// equivalent.
    case glassesUnavailable(underlying: String)
    /// The phone's own microphone/audio session — only reachable when
    /// `AudioSource.phoneMic` is selected.
    case microphoneUnavailable(underlying: String)
    /// Session recovery (device or signed-in) failed outright — no
    /// usable credential could be established at all.
    case authenticationFailed(underlying: String)
    /// The backend explicitly rate-limited session recovery
    /// (`/auth/device` → `429`/`RATE_LIMITED`) — see
    /// `AuthenticatedAPIClientError.rateLimited`'s own doc comment.
    /// Deliberately distinct from `.authenticationFailed`: the
    /// credential itself was never judged invalid, the backend is just
    /// temporarily declining new anonymous sessions from this device —
    /// a truthful, bounded-in-time message, never "check your G2
    /// connection" and never the misleadingly generic "your session
    /// couldn't be verified" a 429 used to produce before this fix.
    case rateLimited(retryAfterSeconds: Int)
    /// Reached the network layer but the backend itself is unreachable
    /// or erroring — offline, timeout, or a 5xx response.
    case backendUnavailable(underlying: String)
    /// A session credential exists and the backend is reachable, but the
    /// realtime-transcription WebSocket handshake itself failed for a
    /// reason other than authentication (a non-101 upgrade response, or
    /// the underlying socket erroring before ever exchanging a message).
    case sttHandshakeFailed(underlying: String)
    /// Anything that doesn't cleanly classify as one of the above —
    /// still surfaced honestly as "unknown," never silently folded into
    /// the G2 message.
    case unknown(underlying: String)

    /// The one user-facing message for each case — never claims G2 is
    /// the problem unless it genuinely is.
    var userFacingMessage: String {
        switch self {
        case .glassesUnavailable:
            "Couldn't start Live Translation. Check your G2 connection and try again."
        case .microphoneUnavailable:
            "Couldn't start Live Translation. Check your microphone and try again."
        case .authenticationFailed:
            "Couldn't start Live Translation. Your session couldn't be verified — try again in a moment."
        case .rateLimited(let seconds):
            "Couldn't start Live Translation. Too many session attempts — try again in \(seconds)s."
        case .backendUnavailable:
            "Couldn't start Live Translation. Check your internet connection and try again."
        case .sttHandshakeFailed:
            "Couldn't start Live Translation. The translation service is temporarily unavailable — try again."
        case .unknown:
            "Couldn't start Live Translation. Try again."
        }
    }

    /// Short, stable tag for `LIVE_START_FAILED stage=` — never the
    /// underlying error text (already logged separately as
    /// `errorMessage=`).
    var stage: String {
        switch self {
        case .glassesUnavailable: "glassesUnavailable"
        case .microphoneUnavailable: "microphoneUnavailable"
        case .authenticationFailed: "authenticationFailed"
        case .rateLimited: "rateLimited"
        case .backendUnavailable: "backendUnavailable"
        case .sttHandshakeFailed: "sttHandshakeFailed"
        case .unknown: "unknown"
        }
    }

    /// Classifies whatever `transcriber.startTranscribing(pcmUpdates:)`
    /// threw. Deliberately never returns `.glassesUnavailable`/
    /// `.microphoneUnavailable` — those are only ever produced directly
    /// by the audio/G2 setup catch block in `LiveTranslationService
    /// .start()`, which knows which `AudioSource` was active; this
    /// function only sees the transcriber/network layer.
    static func classifyTranscriberStartFailure(_ error: Error) -> LiveTranslationStartError {
        if let apiError = error as? AuthenticatedAPIClientError {
            switch apiError {
            case .offline:
                return .backendUnavailable(underlying: apiError.localizedDescription)
            case .rateLimited(let retryAfterSeconds):
                return .rateLimited(retryAfterSeconds: retryAfterSeconds)
            case .notAuthenticated, .sessionExpired:
                return .authenticationFailed(underlying: apiError.localizedDescription)
            case .http(let status, _):
                return status >= 500
                    ? .backendUnavailable(underlying: apiError.localizedDescription)
                    : .authenticationFailed(underlying: apiError.localizedDescription)
            case .invalidResponse, .underlying:
                return .backendUnavailable(underlying: apiError.localizedDescription)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed:
                return .backendUnavailable(underlying: urlError.localizedDescription)
            default:
                return .sttHandshakeFailed(underlying: urlError.localizedDescription)
            }
        }
        return .unknown(underlying: "\(error)")
    }
}
