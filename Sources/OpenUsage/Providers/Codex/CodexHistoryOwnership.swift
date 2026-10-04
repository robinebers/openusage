import Foundation

/// Which Codex homes' local history belongs to one account card. Rollouts never record the paying
/// account, so a home's history belongs to whoever is signed in there now: a switch in a shared home
/// moves that home's whole history to the new login, which is the accepted trade-off. Ownership is
/// re-read on every scan so a mid-session switch takes effect without a relaunch.
struct CodexHistoryOwnership: Sendable {
    let identity: CodexAccountIdentity
    /// Every home any account card may own, standardized.
    let homes: [String]
    /// The configured default homes, whose login may live in the Keychain instead of `auth.json`.
    let defaultHomes: Set<String>
    /// xswap account homes apart from its main home, keyed to the account xswap registered there.
    let registeredOwners: [String: CodexAccountIdentity]
    let files: TextFileAccessing
    let keychainOwner: @Sendable () -> CodexAccountIdentity?

    func owner(of home: String) -> CodexAccountIdentity? {
        let text: String?
        do {
            text = try files.readTextIfPresent(home + "/auth.json")
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "history owner unreadable for \(home); leaving its history unassigned")
            return nil
        }
        if let text, let auth = CodexAuthStore.parseAuth(text), auth.tokens?.accessToken?.nilIfEmpty != nil {
            return CodexAccountIdentity(auth: auth)
        }
        if let registered = registeredOwners[home] { return registered }
        return defaultHomes.contains(home) ? keychainOwner() : nil
    }

    func partition() -> (owned: [String], foreign: [String]) {
        var owned: [String] = []
        var foreign: [String] = []
        for home in homes {
            if owner(of: home) == identity { owned.append(home) } else { foreign.append(home) }
        }
        return (owned, foreign)
    }

    /// History from tools outside Codex homes, such as OpenCode, follows the default login.
    var ownsDefaultLogin: Bool {
        defaultHomes.sorted().contains { owner(of: $0) == identity }
    }
}
