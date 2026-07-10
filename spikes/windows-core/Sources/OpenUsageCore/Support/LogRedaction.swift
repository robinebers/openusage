import Foundation

/// Net-new, faithful port of the Tauri redaction functions (`src-tauri/src/plugin_engine/host_api.rs`
/// `redact_value`/`redact_url`/`redact_body`/`redact_log_message`). Pure, `Sendable`, no I/O.
///
/// `redactLogMessage` is the lightweight last line of defense every `AppLog` line passes through, but
/// it is URL- and body-unaware by design (matching the Rust `redact_log_message`). Any caller that logs
/// a URL or a response body MUST pre-redact it via `redactURL` / `bodyPreview` first — those handle the
/// query-parameter and JSON-key surfaces `redactLogMessage` deliberately does not.
///
/// The regexes reproduce the exact Rust patterns (including the `{12,}` quantifier *after* the
/// prefix, the optional-quote api-key variant in `redactBody` versus the no-quote variant in
/// `redactLogMessage`, and the unique `account=` pass). They are compiled once as static `let`s.
enum LogRedaction {
    // MARK: - Value masking

    /// Redact a sensitive value to `first4...last4`, or `[REDACTED]` when it is too short to mask
    /// safely. Character-based (not byte-based) to match Rust's `char` semantics.
    static func redactValue(_ value: String) -> String {
        let chars = Array(value)
        if chars.count <= 12 {
            return "[REDACTED]"
        }
        let first4 = String(chars.prefix(4))
        let last4 = String(chars.suffix(4))
        return "\(first4)...\(last4)"
    }

    // MARK: - URL

    /// Lowercased substring match list for sensitive query-parameter names (matches Rust's
    /// `sensitive_params`). A parameter is redacted when its lowercased name *contains* any of these
    /// and its value is non-empty; the original name casing is preserved.
    private static let urlSensitiveParams = [
        "key", "api_key", "apikey", "token", "access_token", "secret", "password",
        "auth", "authorization", "bearer", "credential", "user", "user_id", "userid",
        "account_id", "accountid", "profilearn", "profile_arn", "email", "login"
    ]

    /// Redact sensitive query parameters in a URL. Only the query string is touched; the path is
    /// left intact (paths are handled by `redactBody`/`redactLogMessage`).
    static func redactURL(_ url: String) -> String {
        guard let queryStart = url.firstIndex(of: "?") else { return url }
        let base = String(url[..<url.index(after: queryStart)]) // includes the '?'
        let query = String(url[url.index(after: queryStart)...])

        let redactedParams = query.split(separator: "&", omittingEmptySubsequences: false).map { rawParam -> String in
            let param = String(rawParam)
            guard let eqPos = param.firstIndex(of: "=") else { return param }
            let name = String(param[..<eqPos])
            let value = String(param[param.index(after: eqPos)...])
            let nameLower = name.lowercased()
            if !value.isEmpty, urlSensitiveParams.contains(where: { nameLower.contains($0) }) {
                return "\(name)=\(redactValue(value))"
            }
            return param
        }
        return base + redactedParams.joined(separator: "&")
    }

    // MARK: - Body

    /// JSON keys whose values are redacted in a body (matches Rust's `sensitive_keys`).
    private static let jsonSensitiveKeys = [
        "name", "password", "token", "access_token", "refresh_token", "secret", "api_key",
        "apiKey", "authorization", "bearer", "credential", "session_token", "sessionToken",
        "auth_token", "authToken", "id_token", "idToken", "accessToken", "refreshToken",
        "user_id", "userId", "account_id", "accountId", "team_id", "teamId", "org_id", "orgId",
        "account_display_name", "accountDisplayName", "payment_id", "paymentId", "profile_arn",
        "profileArn", "email", "login", "analytics_tracking_id"
    ]

    /// Redact sensitive patterns in a response body for logging. Five ordered passes, matching the
    /// Rust `redact_body`: JWT, quoted api-key, devin-session, the 36 JSON keys, then filesystem
    /// paths. Redact BEFORE any truncation so a secret straddling the cut is still caught intact.
    static func redactBody(_ body: String) -> String {
        var result = body
        result = replaceAll(jwtRegex, in: result) { redactValue($0) }
        result = replaceAll(apiKeyQuotedRegex, in: result) { match in
            let key = match.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return redactValue(key)
        }
        result = replaceAll(devinRegex, in: result) { redactValue($0) }
        for key in jsonSensitiveKeys {
            // Match "key": "value" or "key":"value" — capture group 1 is the value.
            guard let regex = jsonKeyRegexCache[key] else { continue }
            result = replaceGroup1(regex, in: result) { value in
                "\"\(key)\": \"\(redactValue(value))\""
            }
        }
        result = pathRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[PATH]"
        )
        return result
    }

    /// Redact a body, then truncate to a Character-safe preview with a byte-count suffix. Mirrors the
    /// Tauri host_api preview (`{}... ({} bytes total)`), measured on the *original* body's UTF-8
    /// byte length. Any provider that ever needs to log a body MUST route it through here.
    static func bodyPreview(_ body: String, limit: Int = 500) -> String {
        let redacted = redactBody(body)
        guard redacted.utf8.count > limit else { return redacted }
        // UTF-8 safe truncation: include a character while its STARTING byte offset is < limit,
        // mirroring Rust's `char_indices().take_while(|(i, _)| *i < limit)` exactly.
        var truncated = ""
        var byteOffset = 0
        for character in redacted {
            if byteOffset >= limit { break }
            truncated.append(character)
            byteOffset += String(character).utf8.count
        }
        return "\(truncated)... (\(body.utf8.count) bytes total)"
    }

    // MARK: - Log message

    /// Lightweight redaction for free-form log messages. Five ordered passes matching the Rust
    /// `redact_log_message`: JWT, the NO-QUOTE api-key variant, devin-session, the unique `account=`
    /// pass, then filesystem paths.
    static func redactLogMessage(_ message: String) -> String {
        var result = message
        result = replaceAll(jwtRegex, in: result) { redactValue($0) }
        result = replaceAll(apiKeyBareRegex, in: result) { redactValue($0) }
        result = replaceAll(devinRegex, in: result) { redactValue($0) }
        result = replaceAccountEq(in: result)
        result = pathRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[PATH]"
        )
        return result
    }

    // MARK: - Compiled patterns (EXACT Rust patterns, compiled once)

    private static let jwtRegex = makeRegex(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
    private static let apiKeyQuotedRegex = makeRegex(#"["']?(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}["']?"#)
    private static let apiKeyBareRegex = makeRegex(#"(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}"#)
    private static let devinRegex = makeRegex(#"devin-session-token\$[^\s"',}\]]+"#)
    private static let accountRegex = makeRegex(#"(account=)([^,\s]+)"#)
    private static let pathRegex = makeRegex(#"(/(?:Users|home|opt|private|var|tmp|Applications)/[^\s"')]+)"#)

    /// One compiled regex per sensitive JSON key (`"<key>":\s*"([^"]+)"`), built once.
    private static let jsonKeyRegexCache: [String: NSRegularExpression] = {
        var cache: [String: NSRegularExpression] = [:]
        for key in jsonSensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            cache[key] = makeRegex("\"\(escaped)\":\\s*\"([^\"]+)\"")
        }
        return cache
    }()

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // Patterns are static literals ported verbatim from Rust; a failure here is a programmer
        // error, so fail loudly rather than silently disabling redaction.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("LogRedaction: invalid regex pattern: \(pattern)")
        }
        return regex
    }

    // MARK: - Regex replacement helpers

    /// Replace every full match of `regex` in `input` using `transform` on the matched substring.
    /// Walks matches in reverse so earlier ranges stay valid as later ones are replaced.
    private static func replaceAll(
        _ regex: NSRegularExpression,
        in input: String,
        transform: (String) -> String
    ) -> String {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }

    /// Replace every match of `regex`, passing capture group 1 to `transform`. The whole match is
    /// replaced with `transform`'s output. Reverse order keeps ranges valid.
    private static func replaceGroup1(
        _ regex: NSRegularExpression,
        in input: String,
        transform: (String) -> String
    ) -> String {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range, in: result),
                  let groupRange = Range(match.range(at: 1), in: result)
            else { continue }
            let value = String(result[groupRange])
            result.replaceSubrange(fullRange, with: transform(value))
        }
        return result
    }

    /// The `account=<value>` pass: keep the `account=` prefix, redact only the value (group 2).
    private static func replaceAccountEq(in input: String) -> String {
        let matches = accountRegex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range, in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let valueRange = Range(match.range(at: 2), in: result)
            else { continue }
            let prefix = String(result[prefixRange])
            let value = String(result[valueRange])
            result.replaceSubrange(fullRange, with: "\(prefix)\(redactValue(value))")
        }
        return result
    }
}
