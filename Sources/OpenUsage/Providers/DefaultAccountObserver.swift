import Foundation

/// Reads which account is signed in at a family's DEFAULT home — the proven identity slice of the
/// account-first model, with no candidate scanning. An account that can't name itself is reported
/// `unresolved`, never guessed: identity keys only ever come from the provider's own account
/// metadata, so a wrong-account attribution is structurally impossible.
struct DefaultAccountObserver: Sendable {
    /// One family's default-home read this launch.
    enum Outcome: Equatable, Sendable {
        /// The default home named its account.
        case resolved(identityKey: String, label: String?, anchor: String)
        /// A credential footprint exists but nothing names the account (keyring-mode Codex, a
        /// comma-list `CLAUDE_CONFIG_DIR`, a legacy auth file without an account id).
        case unresolved(reason: String)
        /// No sign of a login at the default home.
        case absent
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
    }

    /// Expand a leading `~` against the injected home so tests never touch the real one.
    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    // MARK: - Claude

    /// Claude Code's per-install state file, which names the signed-in account (`oauthAccount`).
    struct ClaudeStateFile: Codable {
        struct OAuthAccount: Codable {
            var accountUuid: String?
            var emailAddress: String?
            var organizationUuid: String?
            var organizationName: String?
        }

        var oauthAccount: OAuthAccount?
    }

    /// Claude identity key: account UUID plus the org UUID when present. Plans are org-scoped — one
    /// human commonly has a personal Max org and a company Team org under the SAME account, and those
    /// are different usage pools that must stay different accounts, never merge.
    static func claudeIdentityKey(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        guard let uuid = account.accountUuid?.nilIfEmpty?.lowercased() else { return nil }
        guard let org = account.organizationUuid?.nilIfEmpty?.lowercased() else { return uuid }
        return "\(uuid)|\(org)"
    }

    /// "email (Org Name)" when both are known — the org is what tells two same-email logins apart.
    static func claudeIdentityLabel(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        let email = account.emailAddress?.nilIfEmpty
        guard let org = account.organizationName?.nilIfEmpty else { return email }
        return email.map { "\($0) (\(org))" } ?? org
    }

    /// The default Claude home, mirroring `ClaudeAuthStore`'s resolution exactly (the observer must
    /// name the account whose credentials the provider actually refreshes with): `CLAUDE_CONFIG_DIR`
    /// when exported, else `~/.claude`. A comma-separated list can't be assigned one identity.
    func observeClaude() -> Outcome {
        var configDir = "~/.claude"
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard !raw.contains(",") else {
                return .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list")
            }
            configDir = raw
        }
        let anchor = expandTilde(configDir)
        // The identity file sits inside a custom config dir, but next to (not inside) the default
        // `~/.claude` — Claude Code keeps the default's state at `~/.claude.json`.
        let identityPath = anchor == expandTilde("~/.claude")
            ? expandTilde("~/.claude.json")
            : anchor + "/.claude.json"
        let text: String?
        do {
            text = try files.readTextIfPresent(identityPath)
        } catch {
            return .unresolved(reason: "identity file unreadable: \(error.localizedDescription)")
        }
        guard let text else {
            // No state file. A credential file without it can't be attributed; no footprint = absent.
            return files.exists(anchor + "/.credentials.json")
                ? .unresolved(reason: "credentials present but no identity file")
                : .absent
        }
        guard let parsed = try? JSONDecoder().decode(ClaudeStateFile.self, from: Data(text.utf8)),
              let account = parsed.oauthAccount,
              let key = Self.claudeIdentityKey(account)
        else {
            return .unresolved(reason: "identity file present but names no account")
        }
        return .resolved(identityKey: key, label: Self.claudeIdentityLabel(account), anchor: anchor)
    }

    // MARK: - Codex

    /// The default Codex homes, mirroring `CodexAuthStore.authPaths()`: `CODEX_HOME` when exported,
    /// else `~/.config/codex` then `~/.codex`. The first home that names its account wins.
    ///
    /// Identity is strict — `tokens.account_id`, or the id_token's ChatGPT account claim (the value
    /// the CLI itself copies into `account_id`). No path-derived fallback: an auth file that can't
    /// name its account (and keyring-mode logins, whose secret we never read here) stays unresolved.
    func observeCodex() -> Outcome {
        let homes: [String]
        if let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            homes = [raw]
        } else {
            homes = ["~/.config/codex", "~/.codex"]
        }

        // `CodexProvider.refresh` falls back to the keychain credential when file auth fails, so
        // while a keychain item exists the file's identity is not provably the account that will
        // produce the next snapshot. We never read the keychain secret here (launch path, prompt
        // risk) — an attributes-only existence probe downgrades the whole family to unresolved,
        // which just means "behave exactly as before account awareness". A later phase binds
        // keyring-mode identities properly. Only a definite "no item" clears the family for file
        // identity: a failed probe (`nil` — locked keychain, denied) is treated the same as
        // "item present", because resolving from the file while the fallback is possible is the
        // exact wrong-account stamp this rule exists to prevent.
        if keychain.genericPasswordExists(service: CodexAuthStore.keychainService) != false {
            return .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        }

        var sawFootprint = false
        for home in homes {
            let anchor = expandTilde(home)
            let text: String?
            do {
                text = try files.readTextIfPresent(anchor + "/auth.json")
            } catch {
                // An unreadable auth file is still a login footprint — just one we can't attribute.
                sawFootprint = true
                continue
            }
            guard let text else { continue }
            sawFootprint = true
            guard let auth = CodexAuthStore.parseAuth(text),
                  auth.tokens?.accessToken?.nilIfEmpty != nil
            else { continue }
            let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
            let email = (payload?["email"] as? String)?.nilIfEmpty
            if let accountID = auth.tokens?.accountID?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return .resolved(identityKey: accountID.lowercased(), label: email, anchor: anchor)
            }
            if let claimID = Self.chatGPTAccountID(inIDTokenPayload: payload) {
                return .resolved(identityKey: claimID.lowercased(), label: email, anchor: anchor)
            }
        }
        return sawFootprint
            ? .unresolved(reason: "credentials present but no account identity")
            : .absent
    }

    /// The account id inside a Codex id_token: `chatgpt_account_id` under the
    /// `https://api.openai.com/auth` claim (the CLI's source for `tokens.account_id`), with the
    /// bare top-level spelling accepted for older tokens.
    static func chatGPTAccountID(inIDTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let authClaim = payload["https://api.openai.com/auth"] as? [String: Any]
        let raw = (authClaim?["chatgpt_account_id"] ?? payload["chatgpt_account_id"]) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
