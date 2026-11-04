import Foundation

extension AccountProviderRuntime {
    /// Reads the banked resets at most once an hour, in the secondary-reads slot. A failure here only
    /// costs the Limit Resets row, never the meters.
    func zaiResets(apiKey: String) async -> [ZAIReset]? {
        guard zaiResetsRead.isDue(at: now()) else { return unexpiredZAIResets }
        do {
            zaiResetsRead.record(try await readZAIResets(apiKey: apiKey), at: now())
        } catch {
            AppLog.warn(
                LogTag.plugin("zai"),
                "\(account.cardID) reset list fetch failed; retrying in an hour: \(error.localizedDescription)"
            )
            zaiResetsRead.record(nil, at: now())
        }
        return unexpiredZAIResets
    }

    /// The last list read, less the resets that have expired since.
    var unexpiredZAIResets: [ZAIReset]? {
        zaiResetsRead.value?.filter { $0.expiresAt > now() }
    }

    /// Spends exactly the record the user confirmed, and only while it is still its window's earliest.
    /// Anything else answers `noCredit`, and the refresh after it shows the list to confirm again. A
    /// request whose answer never arrives is not retried. The post-claim refresh rereads the list.
    func claimZAIReset(_ reset: ZAIReset, requestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("zai")
        let cardID = account.cardID
        let apiKey: String
        let current: [ZAIReset]
        do {
            guard case .apiKey(let key) = try await loadCredential() else { throw ProviderError.invalidResponse }
            apiKey = key
            current = try await readZAIResets(apiKey: apiKey)
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: couldn't read the reset list: \(error.localizedDescription)")
            return .failed(ResetClaimFailure(error))
        }
        guard current.first(where: { $0.window == reset.window }) == reset else {
            AppLog.warn(tag, "\(cardID) reset claim: the confirmed reset is no longer its window's earliest")
            return .noCredit
        }

        let response: HTTPResponse
        do {
            response = try await ZAIUsageClient(http: http).useReset(reset, requestID: requestID, apiKey: apiKey)
        } catch {
            AppLog.error(tag, "\(cardID) reset claim: request failed: \(error.localizedDescription)")
            return .failed(ResetClaimFailure(error))
        }
        let outcome = ZAIResetsMapper.claimOutcome(from: response)
        if outcome == .success {
            AppLog.info(tag, "\(cardID) reset claim: claimed (HTTP \(response.statusCode))")
        } else {
            AppLog.warn(tag, "\(cardID) reset claim: \(outcome) (HTTP \(response.statusCode))")
        }
        return outcome
    }

    private func readZAIResets(apiKey: String) async throws -> [ZAIReset] {
        let response = try await ZAIUsageClient(http: http).fetchResets(apiKey: apiKey)
        try ProviderError.requireSuccess(response, kind: .zai)
        return try ZAIResetsMapper.resets(from: response.body, now: now())
    }
}
