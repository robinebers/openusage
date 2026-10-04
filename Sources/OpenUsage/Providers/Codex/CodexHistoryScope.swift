import Foundation

/// Which local history one Codex card counts.
enum CodexHistoryScope: Equatable, Sendable {
    /// The only Codex card counts every Codex home, pi, and OpenCode.
    case allHomes
    /// One of several account cards counts the homes its account is signed in to, pi when pi's
    /// `openai-codex` login is this account, and OpenCode when the default login is.
    case account(CodexAccountIdentity, CodexHistoryHomes, claimsPiUsage: Bool)

    var claimsPiUsage: Bool {
        guard case let .account(_, _, claimsPiUsage) = self else { return true }
        return claimsPiUsage
    }
}

/// The homes one account card owns in one scan.
struct CodexHistoryClaims: Equatable, Sendable {
    let logHomes: CodexLogHomes
    /// OpenCode history follows the default login.
    let ownsDefaultLogin: Bool
    /// Finding no history means zero spend, not a pending scan. An account card whose home moved to
    /// another login must clear its rows, or the store would keep showing that spend on both cards.
    var emptyIsAuthoritative = false
}

/// The Codex homes account cards divide between them. Rollouts never record the paying account, so a
/// home's history belongs to whoever is signed in there now: a switch in a shared home moves that
/// home's whole history to the new login, which is the accepted trade-off.
struct CodexHistoryHomes: Equatable, Sendable {
    /// Every home any account card may own, standardized, including `defaultHome`.
    let homes: [String]
    /// The home whose login Codex may keep in the Keychain instead of `auth.json`.
    let defaultHome: String
    /// xswap account homes apart from its main home, keyed to the account xswap registered there.
    let registeredOwners: [String: CodexAccountIdentity]

    /// Re-read on every scan so a switch takes effect without a relaunch. Each home's login is read
    /// once, so one scan never splits a home between two accounts. `authStore` is the card's own, which
    /// sees the Keychain login only when it is this account; that is all ownership needs.
    func claims(for identity: CodexAccountIdentity, authStore: CodexAuthStore) -> CodexHistoryClaims {
        var owned: [URL] = []
        var foreign: [URL] = []
        var ownsDefaultLogin = false
        var resolvedEveryHome = true
        for home in homes {
            let owner: CodexAccountIdentity?
            do {
                owner = try self.owner(of: home, authStore: authStore)
            } catch {
                AppLog.warn(LogTag.plugin("codex"), "history owner unreadable for \(home); leaving its history unassigned")
                resolvedEveryHome = false
                owner = nil
            }
            let isOwned = owner == identity
            if home == defaultHome { ownsDefaultLogin = isOwned }
            if isOwned { owned.append(URL(fileURLWithPath: home)) } else { foreign.append(URL(fileURLWithPath: home)) }
        }
        return CodexHistoryClaims(
            logHomes: CodexLogHomes(read: owned, foreign: foreign, cache: homes.map { URL(fileURLWithPath: $0) }),
            ownsDefaultLogin: ownsDefaultLogin,
            emptyIsAuthoritative: resolvedEveryHome
        )
    }

    /// A login that can't name its account falls back to the registry or the Keychain: crediting the
    /// likely owner beats hiding the spend.
    private func owner(of home: String, authStore: CodexAuthStore) throws -> CodexAccountIdentity? {
        if let signedIn = try CodexHomeScanner.signedInIdentity(home: home, files: authStore.files) {
            return signedIn
        }
        if let registered = registeredOwners[home] { return registered }
        guard home == defaultHome else { return nil }
        return authStore.loadKeychainAuth(account: CodexAuthStore.keychainAccount(codexHome: home))
            .flatMap { CodexAccountIdentity(auth: $0.auth) }
    }
}
