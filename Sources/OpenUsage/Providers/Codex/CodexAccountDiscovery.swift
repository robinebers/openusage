import Foundation

/// Finds additional Codex CLI logins on this Mac, from both places the CLI can keep them:
///
/// - **Files:** every sibling `~/.codex*` dir holding an `auth.json` with a usable OAuth access
///   token (a second login lives in a second `CODEX_HOME`; the CLI never reads `~/.config/codex`).
/// - **Keychain:** in the CLI's keyring mode `auth.json` is deleted and the login lives as a
///   generic-password item — one shared service (`Codex Auth`), one account attribute per login
///   (`cli|<hash of the canonical home dir>`). An attributes-only enumeration (no secret read, no
///   unlock prompt) lists them all.
///
/// A dir and a keychain item that hash to the same account collapse into one entry (reusing
/// `CodexAuthStore.keychainAccountName(forConfigDir:)`, never a second copy of the derivation); a
/// keychain item with no matching dir stands alone as a keychain-only account. The default
/// instance's own home (env `CODEX_HOME`, else the default homes) and its hash are reserved for the
/// default account. Checks are one level deep only — never a disk-wide search.
struct CodexAccountDiscovery {
    var authStore: CodexAuthStore
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    /// Names of the immediate children of a directory. Injected so the `~/.codex*` sibling scan is
    /// testable without touching the real home directory.
    var contentsOfDirectory: @Sendable (String) -> [String]

    init(
        authStore: CodexAuthStore = CodexAuthStore(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        contentsOfDirectory: @escaping @Sendable (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    ) {
        self.authStore = authStore
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.contentsOfDirectory = contentsOfDirectory
    }

    func discoverExtraAccounts() -> [DiscoveredAccount] {
        // The default account owns its resolved homes (env override or the default candidates) and
        // their derived keychain accounts; nothing found there may become an extra account.
        let defaultDirs = Set(defaultHomes().map(Self.canonicalize))
        var consumedKeychainAccounts = Set(defaultDirs.map(CodexAuthStore.keychainAccountName(forConfigDir:)))

        let enumerated = enumeratedKeychainAccounts()
        var accounts: [DiscoveredAccount] = []

        for dir in candidateDirs() where !defaultDirs.contains(dir) {
            let hasUsableAuthFile = authStore
                .loadAuth(at: "\(dir)/auth.json")?.hasUsableAccessToken == true
            let keychainAccount = CodexAuthStore.keychainAccountName(forConfigDir: dir)
            let matched = enumerated.contains(keychainAccount) && !consumedKeychainAccounts.contains(keychainAccount)
            guard hasUsableAuthFile || matched else { continue }
            if matched { consumedKeychainAccounts.insert(keychainAccount) }
            accounts.append(DiscoveredAccount(
                configDir: dir,
                keychainService: matched ? CodexAuthStore.keychainService : nil,
                keychainAccount: matched ? keychainAccount : nil
            ))
        }

        for keychainAccount in enumerated.subtracting(consumedKeychainAccounts).sorted() {
            accounts.append(DiscoveredAccount(
                configDir: nil,
                keychainService: CodexAuthStore.keychainService,
                keychainAccount: keychainAccount
            ))
        }

        return accounts
    }

    /// The homes the DEFAULT instance reads (mirrors `CodexAuthStore.authPaths()`): the env
    /// `CODEX_HOME` when set, else both default candidates.
    private func defaultHomes() -> [String] {
        if let home = authStore.codexHome() { return [expandHome(home)] }
        return ["\(homeDirectory().path)/.config/codex", "\(homeDirectory().path)/.codex"]
    }

    /// Candidate extra homes, canonicalized and deduped: every `~/.codex*` sibling dir. One level
    /// deep by design — a home dir listing plus one file stat per candidate.
    private func candidateDirs() -> [String] {
        let home = homeDirectory().path
        var seen = Set<String>()
        var dirs: [String] = []
        for name in contentsOfDirectory(home).sorted() where name.hasPrefix(".codex") {
            let canonical = Self.canonicalize("\(home)/\(name)")
            if seen.insert(canonical).inserted { dirs.append(canonical) }
        }
        return dirs
    }

    /// Every `cli|…` login item under the shared service. Non-`cli|` accounts (the Secrets-mode
    /// passphrase entries live under a different service entirely, but be conservative) are ignored.
    private func enumeratedKeychainAccounts() -> Set<String> {
        do {
            let accounts = try keychain.genericPasswordAccounts(forService: CodexAuthStore.keychainService)
            return Set(accounts.filter { $0.hasPrefix("cli|") })
        } catch {
            AppLog.warn(.keychain, "Codex account enumeration failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Resolve symlinks and strip a trailing slash so two spellings of one dir compare, dedupe, and
    /// hash as the same account — the CLI canonicalizes the same way before hashing.
    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: expandHome(path)).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
