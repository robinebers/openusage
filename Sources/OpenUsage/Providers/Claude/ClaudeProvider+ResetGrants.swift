import Foundation

/// The last reset-grants answer for one login. A failed attempt keeps the previous line and still counts
/// as the hour's check, so an outage or 429 is retried an hour later rather than every refresh.
struct ClaudeResetGrantsCheck {
    var credentialFingerprint: Data
    var checkedAt: Date
    var line: MetricLine?
}

extension ClaudeProvider {
    static let resetGrantsCheckInterval: TimeInterval = 60 * 60

    /// The Rate Limit Resets row, asking Anthropic at most once an hour per login. Claude Code itself only
    /// asks occasionally, and sending the reset-grants request on every refresh came with sustained 429s
    /// on the usage endpoint (issue #1355). Runs after a successful usage fetch, so the token is known-good
    /// and a failure here only costs the row, never the bars.
    func resetGrantsLine(credentials: ClaudeOAuth) async -> MetricLine? {
        let fingerprint = Self.credentialFingerprint(credentials)
        let now = now()
        let previous = resetGrantsCheck?.credentialFingerprint == fingerprint ? resetGrantsCheck : nil
        if let previous, now.timeIntervalSince(previous.checkedAt) < Self.resetGrantsCheckInterval {
            return previous.line.map { ClaudeUsageMapper.droppingElapsedResetGrants($0, now: now) }
        }
        do {
            let response = try await usageClient.fetchResetGrants(
                accessToken: credentials.accessToken ?? "", config: authStore.oauthConfig()
            )
            let line = try ClaudeUsageMapper.mapResetGrantsResponse(response, now: now)
            resetGrantsCheck = ClaudeResetGrantsCheck(credentialFingerprint: fingerprint, checkedAt: now, line: line)
            return line
        } catch {
            let held = previous?.line.map { ClaudeUsageMapper.droppingElapsedResetGrants($0, now: now) }
            // A cancelled refresh is not a verdict on the endpoint; let the next refresh try again.
            guard !Task.isCancelled else { return held }
            AppLog.warn(LogTag.plugin("claude"), "reset grants lookup failed; retrying in an hour: \(error.localizedDescription)")
            resetGrantsCheck = ClaudeResetGrantsCheck(credentialFingerprint: fingerprint, checkedAt: now, line: previous?.line)
            return held
        }
    }
}
