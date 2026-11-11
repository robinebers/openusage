import Foundation

struct ClaudeResetGrantsCheck {
    var checkedAt: Date
    var status: ClaudeResetGrantStatus?
}

struct ClaudeResetGrantsState {
    var check: ClaudeResetGrantsCheck?
    var claimEpoch = 0
    /// Each grant's claim whose answer never arrived, by grant id, with the request id it was sent under.
    var unsettledClaims: [String: String] = [:]

    func isOlder(than age: TimeInterval, at now: Date) -> Bool {
        check.map { now.timeIntervalSince($0.checkedAt) >= age } ?? true
    }

    mutating func settleClaim(grantID: String, outcome: ResetClaimOutcome, resetsLeft: Int?) {
        claimEpoch += 1
        check?.checkedAt = .distantPast
        guard outcome == .success, var status = check?.status,
              let index = status.grants.firstIndex(where: { $0.id == grantID })
        else { return }
        status.grants[index].resetsLeft = max(0, resetsLeft ?? status.grants[index].resetsLeft - 1)
        check?.status = status
    }
}

extension AccountProviderRuntime {
    /// Reads the login's reset grants, at most once an hour in the secondary-reads slot. Claude Code itself
    /// only asks occasionally, and sending the reset-grants request on every refresh brought sustained 429s
    /// on the usage endpoint. A failure here only costs the row, never the bars. A read that can't connect
    /// before the first answer, such as a Mac waking with no network, stays due for the next pass.
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
            let offlineBeforeAnswer = previous == nil && ResetClaimFailure(error) == .connection
            AppLog.warn(
                LogTag.plugin("claude"),
                "\(account.cardID) reset grants lookup failed; retrying \(offlineBeforeAnswer ? "on the next pass" : "in an hour"): \(error.localizedDescription)"
            )
            session.resetGrants.check = offlineBeforeAnswer ? nil : ClaudeResetGrantsCheck(checkedAt: now, status: previous?.status)
        }
    }

    /// Spends a reset from the grant on the row the user chose, as Claude Code does, not Anthropic's
    /// next grant.
    func claimClaudeResetGrant(_ grantID: String, redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("claude")
        let cardID = account.cardID
        guard let session = claude.session, let status = session.resetGrants.check?.status,
              let chosen = status.claimableGrant(grantID)
        else {
            AppLog.warn(tag, "\(cardID) reset claim: the chosen grant has no reset left in the last reset-grants check")
            return .noCredit
        }
        // A claim whose answer never arrived may have landed. Retrying it under its original request id
        // lets Anthropic answer `already_used` instead of spending another reset from the same grant.
        let requestID = session.resetGrants.unsettledClaims[grantID] ?? redeemRequestID
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
            session.resetGrants.unsettledClaims[grantID] = requestID
            return .failed(ResetClaimFailure(error))
        }
        let succeeded = (200..<300).contains(response.statusCode)
        let body = succeeded ? ProviderParse.jsonObject(response.body) : nil
        if body?["result"] != nil {
            session.resetGrants.unsettledClaims[grantID] = nil
        } else if succeeded || response.statusCode >= 500 {
            session.resetGrants.unsettledClaims[grantID] = requestID
        }
        let next = status.nextGrantID.flatMap { id in status.grants.first { $0.id == id } }?.kind
        // A renewable sign-in was already renewed and retried, so a 401 that survives is a scope refusal.
        let outcome: ResetClaimOutcome = response.statusCode == 401 && tokens.refreshToken != nil
            ? .failed(.notPermitted)
            : ClaudeUsageMapper.resetClaimOutcome(from: response, next: next == chosen.kind ? nil : next)
        if outcome == .success {
            AppLog.info(tag, "\(cardID) reset claim: claimed (HTTP \(response.statusCode))")
        } else {
            AppLog.warn(tag, "\(cardID) reset claim: \(outcome) (HTTP \(response.statusCode))")
        }
        switch outcome {
        case .success, .unconfirmed, .noCredit, .notNextReset:
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
