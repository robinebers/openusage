import Foundation

extension ClaudeProvider {
    /// Spends the next reset grant (`next_grant_id` from the hourly reset-grants check). Lives on the
    /// provider so credential selection can't drift from `refresh()`. Never throws: every failure is
    /// logged and collapsed to an outcome. See docs/research/claude-reset-grant-claim.md.
    func claimResetGrant(redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("claude")
        guard let grantID = resetGrantsCheck?.status?.claimableGrantID else {
            AppLog.warn(tag, "reset claim: no claimable grant in the last reset-grants check")
            return .noCredit
        }
        guard Self.matches(grantID, Self.grantIDPattern), Self.matches(redeemRequestID, Self.requestIDPattern) else {
            AppLog.error(tag, "reset claim: refusing a malformed grant id or request id")
            return .failed
        }

        let (candidates, initialGeneration) = await resetClaimCandidates()
        guard !candidates.isEmpty else {
            AppLog.error(tag, "reset claim: no usable Claude credentials")
            return .failed
        }

        var generation = initialGeneration
        var lastRejection: Int?
        for initial in candidates {
            var state = initial
            guard await refreshIfNeeded(&state, generation: &generation) else { continue }
            let accessToken = state.oauth.accessToken ?? ""

            let organizationUUID: String
            switch await claimOrganization(for: state.oauth, accessToken: accessToken) {
            case .found(let uuid):
                organizationUUID = uuid
            case .rejected(let status):
                lastRejection = status
                continue
            case .failed:
                return .failed
            }

            let response: HTTPResponse
            do {
                response = try await usageClient.claimResetGrant(
                    accessToken: accessToken, organizationUUID: organizationUUID,
                    grantID: grantID, requestID: redeemRequestID, config: authStore.oauthConfig()
                )
            } catch {
                AppLog.error(tag, "reset claim: request failed: \(error.localizedDescription)")
                return .failed
            }
            // Safe to retry with the next login: the same request_id can't spend twice.
            if response.statusCode == 401 || response.statusCode == 403 {
                lastRejection = response.statusCode
                continue
            }
            let outcome = Self.resetClaimOutcome(from: response)
            let preview = LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 500)
            if outcome == .success {
                AppLog.info(tag, "reset claim: \(response.statusCode) \(preview)")
            } else {
                AppLog.error(tag, "reset claim: \(outcome) (\(response.statusCode)): \(preview)")
            }
            if outcome != .failed {
                // Re-read grants on the next refresh instead of showing a spent reset for an hour.
                resetGrantsCheck = nil
            }
            return outcome
        }
        AppLog.error(tag, "reset claim: rejected for every credential (last: \(lastRejection.map(String.init) ?? "none"))")
        return .failed
    }

    /// Usable logins, led by the one the grants were read with.
    private func resetClaimCandidates() async -> ([ClaudeCredentialState], ClaudeCredentialGeneration) {
        let load = await loadOffMainActor { [authStore] in authStore.loadCredentialSet() }
        let usable = load.candidates.filter {
            $0.hasUsableAccessToken && authStore.liveUsageAvailability($0) == .available
        }
        let checked = resetGrantsCheck?.credentialFingerprint
        let ordered = usable.filter { Self.credentialFingerprint($0.oauth) == checked }
            + usable.filter { Self.credentialFingerprint($0.oauth) != checked }
        return (ordered, ClaudeCredentialGeneration(load.candidates))
    }

    /// Refreshes a token that's about to expire. Desktop and Swap tokens are renewed by their owners, so
    /// they go out as they are. `false` means the refresh failed and this login is skipped.
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

    private enum OrganizationLookup {
        case found(String)
        case rejected(status: Int)
        case failed
    }

    /// The organization to claim against: cached from the profile request when this token already made
    /// one, otherwise a fresh profile read.
    private func claimOrganization(for oauth: ClaudeOAuth, accessToken: String) async -> OrganizationLookup {
        let tag = LogTag.plugin("claude")
        let uuid: String
        if let cached = cachedOrganizationUUID(for: oauth) {
            uuid = cached
        } else {
            do {
                let response = try await usageClient.fetchProfile(accessToken: accessToken, config: authStore.oauthConfig())
                if response.statusCode == 401 || response.statusCode == 403 {
                    return .rejected(status: response.statusCode)
                }
                guard let organization = try ClaudeUsageClient.decodeProfile(response).organization?.uuid else {
                    AppLog.error(tag, "reset claim: profile carries no organization")
                    return .failed
                }
                uuid = organization
            } catch {
                AppLog.error(tag, "reset claim: profile lookup failed: \(error.localizedDescription)")
                return .failed
            }
        }
        guard UUID(uuidString: uuid) != nil else {
            AppLog.error(tag, "reset claim: refusing a malformed organization id")
            return .failed
        }
        return .found(uuid)
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
