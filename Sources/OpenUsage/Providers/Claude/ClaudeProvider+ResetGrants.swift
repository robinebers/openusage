import Foundation

/// The last reset-grants answer for one login. A failed attempt keeps the previous status and still
/// counts as the hour's check, so an outage or 429 is retried an hour later rather than every refresh.
struct ClaudeResetGrantsCheck {
    var credentialFingerprint: Data
    var checkedAt: Date
    var status: ClaudeResetGrantStatus?
}

extension ClaudeProvider {
    static let resetGrantsCheckInterval: TimeInterval = 60 * 60

    /// The Rate Limit Resets row, asking Anthropic at most once an hour per login. Claude Code itself only
    /// asks occasionally, and sending the reset-grants request on every refresh came with sustained 429s
    /// on the usage endpoint (issue #1355). Runs after a successful usage fetch, so the token is known-good
    /// and a failure here only costs the row, never the bars.
    func resetGrantsLine(
        credentials: ClaudeOAuth,
        expectedGeneration: ClaudeCredentialGeneration,
        forceDesktopFallback: Bool
    ) async throws -> MetricLine? {
        let fingerprint = Self.credentialFingerprint(credentials)
        let now = now()
        let previous = resetGrantsCheck?.credentialFingerprint == fingerprint ? resetGrantsCheck : nil
        if let previous, now.timeIntervalSince(previous.checkedAt) < Self.resetGrantsCheckInterval {
            return previous.status?.line(now: now)
        }
        let epoch = resetClaimEpoch
        do {
            let response = try await usageClient.fetchResetGrants(
                accessToken: credentials.accessToken ?? "", config: authStore.oauthConfig()
            )
            try await checkCredentialGeneration(expectedGeneration, forceDesktopFallback: forceDesktopFallback)
            let status = try ClaudeUsageMapper.mapResetGrantStatus(response)
            // A claim landed while this read was in flight: the answer predates it, so leave the cache
            // empty for the post-claim refresh to re-read.
            guard resetClaimEpoch == epoch else { return status?.line(now: now) }
            resetGrantsCheck = ClaudeResetGrantsCheck(credentialFingerprint: fingerprint, checkedAt: now, status: status)
            return status?.line(now: now)
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            throw error
        } catch {
            let held = previous?.status?.line(now: now)
            // A cancelled refresh is not a verdict on the endpoint; let the next refresh try again.
            guard !Task.isCancelled else { return held }
            try await checkCredentialGeneration(expectedGeneration, forceDesktopFallback: forceDesktopFallback)
            // Checked after the await: a claim during it must not get the pre-claim status put back.
            guard resetClaimEpoch == epoch else { return held }
            AppLog.warn(LogTag.plugin("claude"), "reset grants lookup failed; retrying in an hour: \(error.localizedDescription)")
            resetGrantsCheck = ClaudeResetGrantsCheck(
                credentialFingerprint: fingerprint, checkedAt: now, status: previous?.status
            )
            return held
        }
    }

    func checkCredentialGeneration(
        _ expected: ClaudeCredentialGeneration, forceDesktopFallback: Bool
    ) async throws {
        let current = await loadOffMainActor { [authStore] in
            authStore.credentialGeneration(forceDesktopFallback: forceDesktopFallback)
        }
        guard current == expected else { throw ClaudeAuthError.credentialsChanged }
    }
}
