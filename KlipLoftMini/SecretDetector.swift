import Foundation

/// Recognizes access tokens, API keys and private keys by their fixed shapes, so copies that
/// contain one aren't saved (Settings → Privacy). Only well-known prefixes are matched, to keep
/// ordinary text from being skipped by mistake.
enum SecretDetector {
    private static let patterns = [
        // GitHub: classic, OAuth, user-to-server, server-to-server and refresh tokens, then fine-grained ones.
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{60,}"#,
        // GitLab personal access tokens.
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,
        // AWS access key IDs (long-term and temporary).
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        // Slack tokens and incoming webhooks.
        #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]{20,}"#,
        // Anthropic, then OpenAI keys; OpenAI's need a digit and a capital, so phrases like
        // "sk-learn-tutorial-for-beginners" don't count.
        #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#,
        #"\bsk-(?:proj-|svcacct-|admin-)?(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Z])[A-Za-z0-9_\-]{32,}"#,
        // Stripe live secret and restricted keys.
        #"\b[sr]k_live_[A-Za-z0-9]{20,}"#,
        // Google API keys and OAuth access tokens.
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\bya29\.[0-9A-Za-z_\-]{20,}"#,
        // npm access tokens.
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        // JSON Web Tokens: three base64url parts, the first two starting with {".
        #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
        // PEM and PGP private key blocks (RSA, EC, OpenSSH, encrypted, PGP…).
        #"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
    ]

    private static let regex = try! NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|"))

    /// Very long copies (logs, documents) are only scanned up to this many characters.
    private static let scanLimit = 2_000_000

    static func containsSecret(_ text: String) -> Bool {
        let scanned = text.utf16.count > scanLimit ? String(text.prefix(scanLimit)) : text
        return regex.firstMatch(in: scanned, range: NSRange(scanned.startIndex..., in: scanned)) != nil
    }
}
