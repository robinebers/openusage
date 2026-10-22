import Foundation

extension CodexProvider {
    /// Cards bound to one account try every matching login in order, through the same `probe` the
    /// plain card uses. Read-only sources (xswap, pi, the Keychain) count only while their token is
    /// valid; an independent Codex home refreshes and writes back like the plain card. A login that
    /// changes on disk mid-refresh invalidates the pending result, so the pass starts over once.
    /// Rotated credentials that could not be written back stay in memory; the conflict check compares
    /// the source against what the probe last read or wrote there, not against the working copy.
    func refreshAccount() async -> ProviderSnapshot {
        for _ in 0..<2 {
            var candidates = authStore.loadAuthCandidates()
            if let keychain = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }) {
                candidates.append(keychain)
            }
            var changed = false
            for candidate in candidates {
                guard await authStore.isCurrent(candidate) else { changed = true; break }
                if candidate.readOnly, let token = candidate.auth.tokens?.accessToken,
                   let expiry = authStore.accessTokenExpiresAt(token), expiry <= now() { continue }
                var state = candidate
                var onDisk = candidate
                do {
                    let result = try await probe(authState: &state, onDisk: &onDisk)
                    guard await authStore.isCurrent(onDisk) else { changed = true; break }
                    return result
                } catch let error as CodexAuthError where error.allowsAuthFallback {
                    guard await authStore.isCurrent(onDisk) else { changed = true; break }
                    AppLog.warn(LogTag.auth("codex"), "account credential failed (\(error)); trying a matching login")
                } catch {
                    guard await authStore.isCurrent(onDisk) else { changed = true; break }
                    return ProviderSnapshot.error(provider: provider, error: error)
                }
            }
            if !changed { break }
            AppLog.info(LogTag.auth("codex"), "login changed during usage refresh; discarding the stale result")
        }
        return ProviderSnapshot.error(provider: provider, error: CodexAccountLoginError(managed: hasManagedLogin))
    }
}

/// Points at the place that renews this card's login. A renewal under Codex Accounts rebuilds the
/// card with the renewed home and fetches it; a login made in Codex, xswap, or pi lands in a home
/// the card already reads, so a refresh is enough.
struct CodexAccountLoginError: LocalizedError, CategorizedError {
    let managed: Bool

    var errorCategory: ErrorCategory { .authExpired }
    var errorDescription: String? {
        managed
            ? "No valid login for this Codex account. Use Sign In Again under Customize → Codex → Codex Accounts."
            : "No valid login for this Codex account. Sign in again with Codex, xswap, or pi, then refresh."
    }
}
