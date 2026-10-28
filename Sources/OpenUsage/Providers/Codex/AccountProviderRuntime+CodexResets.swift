import Foundation

extension AccountProviderRuntime {
    func codexResetCredits(after usage: HTTPResponse, accessToken: String, accountID: String?) async -> HTTPResponse? {
        guard (200..<300).contains(usage.statusCode) else { return nil }
        guard codexResetCreditsRead.isDue(at: now()) else { return codexResetCreditsRead.value }
        do {
            let response = try await CodexUsageClient(http: http).fetchResetCredits(accessToken: accessToken, accountID: accountID)
            codexResetCreditsRead.record((200..<300).contains(response.statusCode) ? response : nil, at: now())
        } catch {
            AppLog.warn(
                LogTag.plugin("codex"),
                "\(account.cardID) reset-credit fetch failed; retrying in an hour: \(error.localizedDescription)"
            )
            codexResetCreditsRead.record(nil, at: now())
        }
        return codexResetCreditsRead.value
    }

    func claimCodexResetCredit(expiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("codex")
        let cardID = account.cardID
        let tokens: OAuthTokens
        do {
            tokens = try await freshTokens(try await loadCredential(), grant: CodexLogin.refresh)
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: couldn't prepare the claim: \(error.localizedDescription)")
            return .failed(ResetClaimFailure(error))
        }
        let client = CodexUsageClient(http: http)
        let accountID = tokens.extras["chatgpt_account_id"]

        // A retry of a key that already matched replays the same (key, credit) pair instead of matching
        // again: after a consume whose answer was lost, the credit is gone from the list, and only the
        // replay lets the server's `already_redeemed` prove the claim landed.
        let creditID: String
        if let matched = codexMatchedCreditIDs[redeemRequestID] {
            creditID = matched
        } else {
            let list: HTTPResponse
            do {
                list = try await client.fetchResetCredits(accessToken: tokens.accessToken, accountID: accountID)
            } catch {
                AppLog.error(tag, "\(cardID) reset claim: credit list fetch failed: \(error.localizedDescription)")
                return .failed(ResetClaimFailure(error))
            }
            if ProviderError.isAuthFailure(list) {
                AppLog.error(tag, "\(cardID) reset claim: credit list fetch rejected (HTTP \(list.statusCode))")
                return .failed(.signInExpired)
            }
            guard (200..<300).contains(list.statusCode), let body = ProviderParse.jsonObject(list.body) else {
                AppLog.error(tag, "\(cardID) reset claim: credit list fetch failed (HTTP \(list.statusCode))")
                return .failed(.refused)
            }
            guard let matched = CodexUsageMapper.resetCreditID(in: body, expiringAt: expiry) else {
                AppLog.warn(tag, "\(cardID) reset claim: no available credit matches the picked expiry")
                return .noCredit
            }
            codexMatchedCreditIDs[redeemRequestID] = matched
            creditID = matched
        }

        let response: HTTPResponse
        do {
            response = try await client.consumeResetCredit(
                accessToken: tokens.accessToken, accountID: accountID,
                creditID: creditID, redeemRequestID: redeemRequestID
            )
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: consume request failed: \(error.localizedDescription)")
            return .failed(ResetClaimFailure(error))
        }
        let outcome = CodexUsageMapper.resetClaimOutcome(from: response)
        codexResetCreditsRead.forget()
        if outcome == .success {
            AppLog.info(tag, "\(cardID) reset claim: claimed (HTTP \(response.statusCode))")
        } else {
            AppLog.warn(tag, "\(cardID) reset claim: \(outcome) (HTTP \(response.statusCode))")
        }
        return outcome
    }
}
