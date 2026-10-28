import Foundation

/// The last reset-grants answer for a Claude account. A failed attempt keeps the previous status and
/// still counts as the hour's check, so an outage or 429 is retried an hour later rather than every
/// refresh.
struct ClaudeResetGrantsCheck {
    var checkedAt: Date
    var status: ClaudeResetGrantStatus?
}

/// Claude reset-grant state for one account, carried across refreshes.
struct ClaudeResetGrantsState {
    var check: ClaudeResetGrantsCheck?
    /// Bumped by each claim that changed the grants, so a grants read that started before it can't cache
    /// the pre-claim answer.
    var claimEpoch = 0
    /// The last claim whose answer never arrived, kept so a retry of that grant reuses its request id.
    var unsettledClaim: (grantID: String, requestID: String)?

    /// A claim changed which grants exist, so the next refresh reads them again.
    mutating func forgetCheck() {
        check = nil
        claimEpoch += 1
    }
}

extension AccountProviderRuntime {
    static let claudeResetGrantsCheckInterval: TimeInterval = 60 * 60

    /// The Rate Limit Resets row, asking Anthropic at most once an hour. Claude Code itself only asks
    /// occasionally, and sending the reset-grants request on every refresh brought sustained 429s on the
    /// usage endpoint. Runs after a successful usage fetch, so the token is known-good and a failure here
    /// only costs the row, never the bars.
    func claudeResetGrantsLine(accessToken: String) async -> MetricLine? {
        let now = self.now()
        let previous = claudeResetGrants.check
        if let previous, now.timeIntervalSince(previous.checkedAt) < Self.claudeResetGrantsCheckInterval {
            return previous.status?.line(now: now)
        }
        let epoch = claudeResetGrants.claimEpoch
        do {
            let response = try await ClaudeUsageClient(httpClient: http)
                .fetchResetGrants(accessToken: accessToken)
            let status = try ClaudeUsageMapper.mapResetGrantStatus(response)
            // A claim that landed while this read was in flight makes it a pre-claim answer, so the cache
            // stays empty for the post-claim refresh to fill.
            if claudeResetGrants.claimEpoch == epoch {
                claudeResetGrants.check = ClaudeResetGrantsCheck(checkedAt: now, status: status)
            }
            return status?.line(now: now)
        } catch {
            let held = previous?.status?.line(now: now)
            // A cancelled refresh is not a verdict on the endpoint, and a claim during the request must not
            // get the pre-claim status put back. Either way the next refresh asks again.
            guard !Task.isCancelled, claudeResetGrants.claimEpoch == epoch else { return held }
            AppLog.warn(
                LogTag.plugin("claude"),
                "\(account.cardID) reset grants lookup failed; retrying in an hour: \(error.localizedDescription)"
            )
            claudeResetGrants.check = ClaudeResetGrantsCheck(checkedAt: now, status: previous?.status)
            return held
        }
    }

    /// Spends the account's next reset grant: `next_grant_id` from the hourly check, claimed with the
    /// account's own sign-in against its own organization. Never throws: every failure is logged without
    /// credentials or response bodies and collapsed to an outcome.
    func claimClaudeResetGrant(redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("claude")
        let cardID = account.cardID
        // Read before any await, so a refresh that replaces the check mid-claim can't change the target.
        guard let grantID = claudeResetGrants.check?.status?.claimableGrantID else {
            AppLog.warn(tag, "\(cardID) reset claim: no claimable grant in the last reset-grants check")
            return .noCredit
        }
        // A claim whose answer never arrived may have landed. Retrying it under its original request id
        // lets Anthropic answer `already_used` instead of spending another reset from the same grant.
        let unsettled = claudeResetGrants.unsettledClaim
        let requestID = unsettled?.grantID == grantID ? unsettled?.requestID ?? redeemRequestID : redeemRequestID
        guard Self.matches(grantID, Self.grantIDPattern), Self.matches(requestID, Self.requestIDPattern) else {
            AppLog.error(tag, "\(cardID) reset claim: refusing a malformed grant id or request id")
            return .failed(.refused)
        }

        let tokens: OAuthTokens
        let organizationUUID: String
        do {
            tokens = try await claudeTokens(try await loadCredential())
            organizationUUID = try await claudeOrganizationUUID(accessToken: tokens.accessToken)
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: couldn't prepare the claim: \(error.localizedDescription)")
            return .failed(ResetClaimFailure(error))
        }

        let response: HTTPResponse
        do {
            response = try await ClaudeUsageClient(httpClient: http).claimResetGrant(
                accessToken: tokens.accessToken, organizationUUID: organizationUUID,
                grantID: grantID, requestID: requestID
            )
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: request failed: \(error.localizedDescription)")
            claudeResetGrants.unsettledClaim = (grantID, requestID)
            return .failed(ResetClaimFailure(error))
        }
        // Only a readable answer settles the request id. A server error or unreadable body leaves it unknown
        // whether the reset was spent, and a 401/403/429 refused this attempt without saying whether an
        // earlier one under the same id landed, so the id is kept for the next retry.
        let succeeded = (200..<300).contains(response.statusCode)
        if succeeded, ProviderParse.jsonObject(response.body)?["result"] != nil {
            claudeResetGrants.unsettledClaim = nil
        } else if succeeded || response.statusCode >= 500 {
            claudeResetGrants.unsettledClaim = (grantID, requestID)
        }
        let outcome = ClaudeUsageMapper.resetClaimOutcome(from: response)
        if outcome == .success {
            AppLog.info(tag, "\(cardID) reset claim: claimed (HTTP \(response.statusCode))")
        } else {
            AppLog.warn(tag, "\(cardID) reset claim: \(outcome) (HTTP \(response.statusCode))")
        }
        switch outcome {
        case .success, .unconfirmed, .noCredit:
            claudeResetGrants.forgetCheck()
        case .nothingToReset, .unavailableNow, .failed:
            break
        }
        return outcome
    }

    /// The organization a claim is made against: `organization.uuid` from the profile of the same token.
    /// The id goes into the claim's URL path, so anything that isn't a UUID is refused.
    private func claudeOrganizationUUID(accessToken: String) async throws -> String {
        let response = try await ClaudeUsageClient(httpClient: http)
            .fetchProfile(accessToken: accessToken)
        if ProviderAuthRetry.isAuthFailure(response) { throw ProviderError.signInExpired(.claude) }
        guard let uuid = try ClaudeUsageClient.decodeProfile(response).organization?.uuid,
              UUID(uuidString: uuid) != nil
        else {
            throw ProviderError.invalidResponse
        }
        return uuid
    }

    private static let grantIDPattern = "^[a-z0-9_-]{1,40}$"
    private static let requestIDPattern = "^[A-Za-z0-9_-]{1,64}$"

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
