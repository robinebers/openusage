import Foundation

struct ClaudeResetGrantsCheck {
    var checkedAt: Date
    var status: ClaudeResetGrantStatus?
}

struct ClaudeResetGrantsState {
    var check: ClaudeResetGrantsCheck?
    var claimEpoch = 0
    var unsettledClaim: (grantID: String, requestID: String)?

    func isOlder(than age: TimeInterval, at now: Date) -> Bool {
        check.map { now.timeIntervalSince($0.checkedAt) >= age } ?? true
    }

    mutating func settleClaim(grantID: String, outcome: ResetClaimOutcome, resetsLeft: Int?) {
        claimEpoch += 1
        guard outcome == .success, var status = check?.status,
              let index = status.grants.firstIndex(where: { $0.id == grantID })
        else {
            check?.checkedAt = .distantPast
            return
        }
        status.grants[index].resetsLeft = max(0, resetsLeft ?? status.grants[index].resetsLeft - 1)
        check?.status = status
    }
}

extension AccountProviderRuntime {
    /// Reads the login's reset grants, at most once an hour in the secondary-reads slot. Claude Code itself
    /// only asks occasionally, and sending the reset-grants request on every refresh brought sustained 429s
    /// on the usage endpoint. A failure here only costs the row, never the bars.
    func readClaudeResetGrants(_ session: ClaudeSession, accessToken: String) async {
        let now = self.now()
        let previous = session.resetGrants.check
        let epoch = session.resetGrants.claimEpoch
        do {
            let client = ClaudeUsageClient(httpClient: http)
            let response = try await session.send(at: now) { try await client.fetchResetGrants(accessToken: accessToken) }
            let status = try ClaudeUsageMapper.mapResetGrantStatus(response)
            if session.resetGrants.claimEpoch == epoch {
                session.resetGrants.check = ClaudeResetGrantsCheck(checkedAt: now, status: status)
            }
        } catch {
            guard !Task.isCancelled, session.resetGrants.claimEpoch == epoch else { return }
            AppLog.warn(
                LogTag.plugin("claude"),
                "\(account.cardID) reset grants lookup failed; retrying in an hour: \(error.localizedDescription)"
            )
            session.resetGrants.check = ClaudeResetGrantsCheck(checkedAt: now, status: previous?.status)
        }
    }

    func claimClaudeResetGrant(redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("claude")
        let cardID = account.cardID
        guard let session = claude.session, let grantID = session.resetGrants.check?.status?.claimableGrantID else {
            AppLog.warn(tag, "\(cardID) reset claim: no claimable grant in the last reset-grants check")
            return .noCredit
        }
        // A claim whose answer never arrived may have landed. Retrying it under its original request id
        // lets Anthropic answer `already_used` instead of spending another reset from the same grant.
        let unsettled = session.resetGrants.unsettledClaim
        let requestID = unsettled?.grantID == grantID ? unsettled?.requestID ?? redeemRequestID : redeemRequestID
        guard Self.matches(grantID, Self.grantIDPattern), Self.matches(requestID, Self.requestIDPattern) else {
            AppLog.error(tag, "\(cardID) reset claim: refusing a malformed grant id or request id")
            return .failed(.refused)
        }

        let tokens: OAuthTokens
        let organizationUUID: String
        do {
            tokens = try await freshTokens(try await loadCredential(), grant: ClaudeLogin.refresh)
            if session.organizationUUID == nil { try await readClaudeProfile(session, tokens: tokens) }
            guard let uuid = session.organizationUUID else { throw ProviderError.invalidResponse }
            organizationUUID = uuid
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: couldn't prepare the claim: \(error.localizedDescription)")
            return .failed(ResetClaimFailure(error))
        }

        let response: HTTPResponse
        do {
            response = try await authorizedRead(.oauth(tokens), grant: ClaudeLogin.refresh) { tokens in
                try await ClaudeUsageClient(httpClient: http).claimResetGrant(
                    accessToken: tokens.accessToken, organizationUUID: organizationUUID,
                    grantID: grantID, requestID: requestID
                )
            }.response
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: request failed: \(error.localizedDescription)")
            session.resetGrants.unsettledClaim = (grantID, requestID)
            return .failed(ResetClaimFailure(error))
        }
        let succeeded = (200..<300).contains(response.statusCode)
        let body = succeeded ? ProviderParse.jsonObject(response.body) : nil
        if body?["result"] != nil {
            session.resetGrants.unsettledClaim = nil
        } else if succeeded || response.statusCode >= 500 {
            session.resetGrants.unsettledClaim = (grantID, requestID)
        }
        let outcome = ClaudeUsageMapper.resetClaimOutcome(from: response)
        if outcome == .success {
            AppLog.info(tag, "\(cardID) reset claim: claimed (HTTP \(response.statusCode))")
        } else {
            AppLog.warn(tag, "\(cardID) reset claim: \(outcome) (HTTP \(response.statusCode))")
        }
        switch outcome {
        case .success, .unconfirmed, .noCredit:
            let resetsLeft = ProviderParse.number(body?["resets_left"]).flatMap { ProviderParse.int($0.rounded(.down)) }
            session.resetGrants.settleClaim(grantID: grantID, outcome: outcome, resetsLeft: resetsLeft)
        case .nothingToReset, .unavailableNow, .failed:
            break
        }
        return outcome
    }

    private static let grantIDPattern = "^[a-z0-9_-]{1,40}$"
    private static let requestIDPattern = "^[A-Za-z0-9_-]{1,64}$"

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
