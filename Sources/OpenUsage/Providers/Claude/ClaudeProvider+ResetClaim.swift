import Foundation

extension ClaudeProvider {
    /// Spends the next reset grant (`next_grant_id` from the hourly reset-grants check). Lives on the
    /// provider so credential selection can't drift from `refresh()`. Never throws: every failure is
    /// logged and collapsed to an outcome. See docs/research/claude-reset-grant-claim.md.
    func claimResetGrant(redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("claude")
        // Read the grant and the login that saw it together, before any await: a refresh for another
        // login could replace the check mid-claim and pair this grant with that login.
        guard let check = resetGrantsCheck, let grantID = check.status?.claimableGrantID else {
            AppLog.warn(tag, "reset claim: no claimable grant in the last reset-grants check")
            return .noCredit
        }
        // A claim whose answer never arrived may have landed. Retrying it under its original request id
        // lets Anthropic answer `already_used` instead of spending another reset from the same grant.
        let requestID = unsettledResetClaim?.grantID == grantID
            ? unsettledResetClaim?.requestID ?? redeemRequestID
            : redeemRequestID
        guard Self.matches(grantID, Self.grantIDPattern), Self.matches(requestID, Self.requestIDPattern) else {
            AppLog.error(tag, "reset claim: refusing a malformed grant id or request id")
            return .failed
        }

        // Only the login the grants were read with may claim. Grant ids are shared promos, so another
        // login on this machine could hold the same id and would spend its own reset instead.
        guard let (found, load) = await resetClaimLogin(fingerprint: check.credentialFingerprint) else {
            AppLog.error(tag, "reset claim: the login the grants were read with is no longer available")
            return .noCredit
        }
        var state = found
        var generation = ClaudeCredentialGeneration(load.candidates)
        guard await refreshIfNeeded(&state, generation: &generation) else { return .failed }
        let accessToken = state.oauth.accessToken ?? ""
        guard let organizationUUID = await claimOrganization(for: state.oauth, accessToken: accessToken) else {
            return .failed
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.claimResetGrant(
                accessToken: accessToken, organizationUUID: organizationUUID,
                grantID: grantID, requestID: requestID, config: authStore.oauthConfig()
            )
        } catch {
            AppLog.error(tag, "reset claim: request failed: \(error.localizedDescription)")
            unsettledResetClaim = (grantID, requestID)
            return .failed
        }
        // Only a readable answer settles the request id. A server error or unreadable body leaves it
        // unknown whether the reset was spent, and a 401/403/429 refused this attempt without saying
        // whether an earlier one under the same id landed, so the id is kept for the next retry.
        let settled = (200..<300).contains(response.statusCode) && ProviderParse.jsonObject(response.body)?["result"] != nil
        if settled {
            unsettledResetClaim = nil
        } else if response.statusCode >= 500 || (200..<300).contains(response.statusCode) {
            unsettledResetClaim = (grantID, requestID)
        }
        let outcome = Self.resetClaimOutcome(from: response)
        let preview = LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 500)
        if outcome == .success {
            AppLog.info(tag, "reset claim: \(response.statusCode) \(preview)")
        } else {
            AppLog.error(tag, "reset claim: \(outcome) (\(response.statusCode)): \(preview)")
        }
        switch outcome {
        case .success, .unconfirmed:
            forgetUsageAfterResetClaim()
        case .noCredit:
            forgetGrantsAfterResetClaim()
        case .nothingToReset, .unavailableNow, .failed:
            break
        }
        return outcome
    }

    /// The login with this fingerprint, plus the load it came from. Falls back to the Desktop-forced
    /// load, because `refresh()` reads grants with the Desktop login when the CLI login is rejected.
    private func resetClaimLogin(fingerprint: Data) async -> (ClaudeCredentialState, ClaudeCredentialLoad)? {
        for forceDesktop in [false, true] {
            let load = await loadOffMainActor { [authStore] in
                authStore.loadCredentialSet(forceDesktopFallback: forceDesktop)
            }
            if let state = load.candidates.first(where: {
                $0.hasUsableAccessToken && Self.credentialFingerprint($0.oauth) == fingerprint
            }) {
                return (state, load)
            }
        }
        return nil
    }

    /// Refreshes a token that's about to expire. Desktop and Swap tokens are renewed by their owners, so
    /// they go out as they are. `false` means the refresh failed.
    private func refreshIfNeeded(
        _ state: inout ClaudeCredentialState, generation: inout ClaudeCredentialGeneration
    ) async -> Bool {
        guard authStore.needsRefresh(state.oauth), state.source != .desktop, state.source != .swapVault,
              let refreshToken = state.oauth.refreshToken, !refreshToken.isEmpty
        else { return true }
        do {
            let refreshed = try await refreshAccessToken(
                state: &state, refreshToken: refreshToken, expectedGeneration: generation
            )
            if refreshed.persisted { generation = generation.replacing(state) }
            return true
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "reset claim: token refresh failed for \(state.source.label): \(error.localizedDescription)")
            return false
        }
    }

    /// The organization to claim against: cached from the profile request when this token already made
    /// one, otherwise a fresh profile read. `nil` (logged) when it can't be established.
    private func claimOrganization(for oauth: ClaudeOAuth, accessToken: String) async -> String? {
        let tag = LogTag.plugin("claude")
        let uuid: String
        if let cached = cachedOrganizationUUID(for: oauth) {
            uuid = cached
        } else {
            do {
                let response = try await usageClient.fetchProfile(accessToken: accessToken, config: authStore.oauthConfig())
                guard let organization = try ClaudeUsageClient.decodeProfile(response).organization?.uuid else {
                    AppLog.error(tag, "reset claim: profile carries no organization")
                    return nil
                }
                uuid = organization
            } catch {
                AppLog.error(tag, "reset claim: profile lookup failed: \(error.localizedDescription)")
                return nil
            }
        }
        guard UUID(uuidString: uuid) != nil else {
            AppLog.error(tag, "reset claim: refusing a malformed organization id")
            return nil
        }
        return uuid
    }

    /// Collapses a claim response to the popover's outcome. Request ids are fresh per confirm, so
    /// `already_used` can only answer our own earlier attempt and counts as claimed.
    static func resetClaimOutcome(from response: HTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let result = body["result"] as? String
        else { return .failed }
        let cooldownUntil = ClaudeUsageMapper.resetDate(body["cooldown_until"])
        func outcome(_ code: String) -> ResetClaimOutcome? {
            switch code {
            case "reset", "already_used": .success
            case "not_limited": .nothingToReset
            case "ineligible", "no_grant", "unknown_grant", "not_next_grant": .noCredit
            case "reset_unconfirmed", "stamp_indeterminate": .unconfirmed
            case "cooldown", "paused", "low_priority_active": .unavailableNow(until: cooldownUntil)
            default: nil
            }
        }
        if result == "unavailable" {
            return (body["reason"] as? String).flatMap(outcome) ?? .failed
        }
        return outcome(result) ?? .failed
    }

    private static let grantIDPattern = "^[a-z0-9_-]{1,40}$"
    private static let requestIDPattern = "^[A-Za-z0-9_-]{1,64}$"

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The resets popover's claim seam for one Claude card: the provider's claim plus a forced refresh, so
/// the result banner appears over already-reconciled meters.
@MainActor
final class ClaudeResetClaimService: ResetClaimService {
    private let provider: ClaudeProvider
    private let refreshAfterClaim: () async -> Void

    init(provider: ClaudeProvider, refreshAfterClaim: @escaping () async -> Void = {}) {
        self.provider = provider
        self.refreshAfterClaim = refreshAfterClaim
    }

    var isClaimable: Bool { provider.resetGrantsCheck?.status?.claimableGrantID != nil }
    var confirmDetail: String? { provider.resetGrantsCheck?.status?.confirmDetail }

    /// Claude always spends `next_grant_id`, so the picked node's expiry is ignored.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let outcome = await provider.claimResetGrant(redeemRequestID: redeemRequestID)
        if outcome != .failed { await refreshAfterClaim() }
        return outcome
    }
}
