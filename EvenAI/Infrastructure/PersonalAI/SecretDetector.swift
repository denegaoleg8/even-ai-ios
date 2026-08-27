import Foundation

/// Gate on every path that could write text into long-term memory (the
/// extractor and the Memory Center's manual add). If this says a string
/// looks like a credential, it is **never stored and never logged** — the
/// caller drops it and, at most, tells the user "that looked like a secret,
/// so I didn't save it".
///
/// This is intentionally trigger-happy: a false positive means a note isn't
/// saved (recoverable), a false negative means a token lands in a memory
/// store that will later sync to the cloud (not recoverable).
enum SecretDetector {
    struct Finding: Equatable, Sendable {
        var kind: String
    }

    private static let patterns: [(kind: String, regex: String)] = [
        ("openai-key", #"\bsk-[A-Za-z0-9_-]{16,}\b"#),
        ("anthropic-key", #"\bsk-ant-[A-Za-z0-9_-]{16,}\b"#),
        ("github-token", #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        ("aws-access-key", #"\bAKIA[0-9A-Z]{12,}\b"#),
        ("google-api-key", #"\bAIza[0-9A-Za-z_-]{20,}\b"#),
        ("slack-token", #"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#),
        ("bearer-token", #"(?i)\bbearer\s+[A-Za-z0-9._-]{20,}\b"#),
        ("jwt", #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#),
        ("private-key-block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("ssh-key", #"\bssh-(rsa|ed25519|dss) [A-Za-z0-9+/]{40,}"#),
        ("password-assignment", #"(?i)\b(password|passwd|pwd|passphrase|secret|api[_ -]?key|token|credential)s?\b\s*(is|=|:|are)\s*\S{4,}"#),
        ("long-hex-blob", #"\b[0-9a-fA-F]{40,}\b"#),
        ("card-number", #"\b(?:\d[ -]?){13,16}\b"#),
    ]

    private static let compiled: [(kind: String, regex: NSRegularExpression)] = patterns.compactMap { entry in
        guard let re = try? NSRegularExpression(pattern: entry.regex) else { return nil }
        return (entry.kind, re)
    }

    /// The first matching secret kind, or `nil` if the text looks safe.
    static func firstFinding(in text: String) -> Finding? {
        let range = NSRange(text.startIndex..., in: text)
        for (kind, re) in compiled where re.firstMatch(in: text, range: range) != nil {
            return Finding(kind: kind)
        }
        return nil
    }

    static func containsSecret(_ text: String) -> Bool {
        firstFinding(in: text) != nil
    }
}
