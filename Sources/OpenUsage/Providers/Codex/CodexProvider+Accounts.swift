import Foundation

extension CodexProvider {
    /// All xswap sources are access-token-only. A changed login invalidates the entire pending result.
    func refreshAccount() async -> ProviderSnapshot {
        for _ in 0..<2 {
            var candidates = authStore.loadAuthCandidates()
            if let keychain = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }) {
                candidates.append(keychain)
            }
            var changed = false
            for initialCandidate in candidates {
                var candidate = initialCandidate
                var currentState = initialCandidate
                guard await authStore.isCurrent(currentState) else { changed = true; break }
                do {
                    if authStore.needsRefresh(candidate.auth),
                       let refreshToken = candidate.auth.tokens?.refreshToken?.nilIfEmpty {
                        let refreshed = try await usageClient.refreshToken(refreshToken)
                        guard await authStore.isCurrent(currentState) else { changed = true; break }
                        let currentIDToken = candidate.auth.tokens?.idToken
                        candidate.auth.tokens?.accessToken = refreshed.accessToken
                        candidate.auth.tokens?.refreshToken = refreshed.refreshToken ?? refreshToken
                        candidate.auth.tokens?.idToken = refreshed.idToken ?? currentIDToken
                        candidate.auth.lastRefresh = OpenUsageISO8601.string(from: now())
                        guard authStore.scoped(candidate) != nil else { changed = true; break }
                        do {
                            try authStore.save(candidate)
                            currentState = candidate
                        } catch {
                            AppLog.error(LogTag.auth("codex"), "failed to persist rotated account credentials: \(error.localizedDescription)")
                        }
                    }
                    guard let token = candidate.auth.tokens?.accessToken,
                          authStore.accessTokenExpiresAt(token).map({ $0 > now() }) ?? true
                    else { continue }
                    let response = try await usageClient.fetchUsage(
                        accessToken: token, accountID: candidate.auth.tokens?.accountID
                    )
                    guard await authStore.isCurrent(currentState) else { changed = true; break }
                    if response.statusCode == 401 || response.statusCode == 403 {
                        AppLog.warn(LogTag.auth("codex"), "account credential rejected; trying a matching login")
                        continue
                    }
                    let resets = await accountResetCredits(candidate)
                    guard await authStore.isCurrent(currentState) else { changed = true; break }
                    let mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resets, now: now())
                    let result = await snapshot(mapped: mapped)
                    guard await authStore.isCurrent(currentState) else { changed = true; break }
                    return result
                } catch {
                    guard await authStore.isCurrent(currentState) else { changed = true; break }
                    return ProviderSnapshot.error(provider: provider, error: error)
                }
            }
            if !changed { break }
            AppLog.info(LogTag.auth("codex"), "login changed during usage refresh; discarding the stale result")
        }
        return ProviderSnapshot.error(provider: provider, error: CodexSwapLoginError())
    }

    private func accountResetCredits(_ candidate: CodexAuthState) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(
                accessToken: candidate.auth.tokens?.accessToken ?? "", accountID: candidate.auth.tokens?.accountID
            )
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }
}

private struct CodexSwapLoginError: LocalizedError, CategorizedError {
    var errorCategory: ErrorCategory { .authExpired }
    var errorDescription: String? {
        "No valid login for this Codex account. Sign in with Codex, xswap, or pi, then refresh."
    }
}
