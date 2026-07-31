import OSLog

/// The app's one logging entry point, wrapping `os.Logger` (Console.app /
/// `log stream` visible, zero extra dependency) instead of `print`/`NSLog`
/// — previously absent everywhere in this app, which is exactly why
/// silent failures (a Keychain write that didn't take, an anonymous
/// session fallback the user never asked for, a stream that died
/// mid-reply) were undiagnosable without attaching a debugger.
///
/// Security rule, not a suggestion: **never** log a token, password, or
/// full email address through any of these categories. Every call site
/// that logs something derived from user data must justify why the
/// specific value logged (an error code, a boolean, a truncated id) is
/// safe to have sitting in the system log. `os.Logger`'s default
/// privacy redaction (`%@` → "<private>" in Console.app for release
/// builds) is a second line of defense, not the reason this rule exists.
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.evenai.app"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let networking = Logger(subsystem: subsystem, category: "networking")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
