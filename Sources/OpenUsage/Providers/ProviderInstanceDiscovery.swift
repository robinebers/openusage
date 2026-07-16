import Foundation

/// Launch-time auto-discovery of extra Claude/Codex logins ("provider instances").
///
/// Runs synchronously in `AppContainer.init` before the registry is built, under a small time budget,
/// and reads **no keychain secrets** — credential presence is checked from file existence and
/// attributes-only keychain probes, so discovery can never raise a macOS permission dialog or block
/// launch (the #987 lesson). The one-time keychain prompt for an extra keychain-backed account happens
/// on that instance's first refresh instead.
///
/// Shape rules (see docs/research/provider-accounts-ux.md §4.3): candidates are dot-dirs at `~` and
/// dirs under `~/.config`, plus Cowork's session sandboxes. A candidate only counts when it carries the
/// provider's exact credential shape AND names its account (identity read from the home itself). A home
/// whose identity matches the default login is folded, never shown twice — that identity routing, not
/// name matching, is what keeps toys, forks, and sandbox homes out.
struct ProviderInstanceDiscovery {
    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: () -> URL
    /// Wall-clock budget; on overrun the scan returns what it has (and the next launch resumes).
    var timeBudget: TimeInterval
    var now: () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        timeBudget: TimeInterval = 0.4,
        now: @escaping () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.timeBudget = timeBudget
        self.now = now
    }

    struct Result {
        var instances: [DiscoveredProviderInstance] = []
        /// Cowork session `.claude` dirs grouped by the account that produced them (non-default only).
        var coworkRootsByIdentityKey: [String: [URL]] = [:]
        /// Set only when a distinct-account Cowork login exists: the default card's partition of the
        /// Cowork walk. `nil` = no partition, keep the scanner's built-in walk byte-identical.
        var defaultClaudeCoworkRoots: [URL]?
        /// The default card's account identity per base provider, as seen THIS launch. Swap tools
        /// (cswap) change the default login in place, so a persisted instance record can suddenly name
        /// the same account the default card now shows — its runtime is suppressed for this launch so
        /// one account never renders as two cards.
        var defaultIdentityKeys: [String: Set<String>] = [:]
        /// The support trail: one line per notable decision (near-miss rejections, same-account folds,
        /// vault/cowork summaries), emitted to the log so a "my account didn't show up" report is
        /// diagnosable from a default log. Token-free and email-free by construction — identity
        /// hashes, kinds, and paths only (the log file gets attached to public issues).
        var notes: [String] = []
    }

    private struct ClaudeIdentity: Codable {
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
    /// are different usage pools that must become different instances, never merge.
    private func claudeIdentityKey(_ account: ClaudeIdentity.OAuthAccount) -> String? {
        guard let uuid = account.accountUuid?.nilIfEmpty else { return nil }
        guard let org = account.organizationUuid?.nilIfEmpty else { return uuid }
        return "\(uuid)|\(org.lowercased())"
    }

    /// "email (Org Name)" when both are known — the org is what tells two same-email logins apart.
    private func claudeIdentityLabel(_ account: ClaudeIdentity.OAuthAccount) -> String? {
        let email = account.emailAddress?.nilIfEmpty
        guard let org = account.organizationName?.nilIfEmpty else { return email }
        return email.map { "\($0) (\(org))" } ?? org
    }

    func run() -> Result {
        let started = now()
        var deadlinePassed = false
        func overBudget() -> Bool {
            if deadlinePassed { return true }
            if now().timeIntervalSince(started) > timeBudget {
                deadlinePassed = true
                AppLog.warn(.config, "provider-instance discovery hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
            }
            return deadlinePassed
        }

        var result = Result()
        var seenIdentityKeys = Set<String>()

        let home = homeDirectory()
        let defaultClaude = defaultClaudeIdentityKey()
        let defaultCodex = defaultCodexIdentityKeys()
        if let defaultClaude { result.defaultIdentityKeys["claude"] = [defaultClaude] }
        if !defaultCodex.isEmpty { result.defaultIdentityKeys["codex"] = defaultCodex }
        let excludedPaths = Set(
            (defaultClaudeConfigDirs() + defaultCodexHomes()).map { canonical($0) }
        )

        let claudeDefaultHash = defaultClaude.map(ProviderInstanceID.hash8) ?? "none"
        let codexDefaultHashes = defaultCodex.map(ProviderInstanceID.hash8).sorted().joined(separator: ",")
        result.notes.append("default identities: claude=\(claudeDefaultHash) codex=[\(codexDefaultHashes)]")

        for candidate in candidateDirectories(home: home) {
            guard !overBudget() else { break }
            let canonicalPath = canonical(candidate.path)
            guard !excludedPaths.contains(canonicalPath) else { continue }

            if let finding = claudeCandidate(at: candidate, defaultIdentityKey: defaultClaude, notes: &result.notes),
               seenIdentityKeys.insert("claude|\(finding.identityKey)").inserted {
                result.instances.append(finding)
            }
            if let finding = codexCandidate(at: candidate, defaultIdentityKeys: defaultCodex, notes: &result.notes),
               seenIdentityKeys.insert("codex|\(finding.identityKey)").inserted {
                result.instances.append(finding)
            }
        }

        // claude-swap (cswap) vault: each PARKED slot's identity comes from the tool's own per-slot
        // config backup — the active slot is exactly what the default card shows, so it is never an
        // instance. Runs before the Cowork walk so a same-account Cowork finding upgrades to the
        // swap-vault credential source instead of the borrowed Desktop token.
        if !overBudget() {
            for finding in claudeSwapSlots(defaultIdentityKey: defaultClaude, notes: &result.notes)
            where seenIdentityKeys.insert("claude|\(finding.identityKey)").inserted {
                result.instances.append(finding)
            }
        }

        // Cowork: identity comes from each session sandbox's own `.claude.json`. Sandboxes matching the
        // default login (the overwhelmingly common case) stay exactly where they are today — on the
        // default card. A distinct account becomes ONE `.claudeDesktop` instance backed by Claude
        // Desktop's credentials, with its sandboxes as that instance's usage logs — unless the same
        // account was already discovered as a config-dir home, in which case the sandboxes just become
        // that instance's extra logs.
        if !overBudget(), let defaultClaude {
            var defaultRoots: [URL] = []
            var foundDistinct = false
            for dir in ClaudeLogUsageScanner.coworkClaudeDirs(home: home) {
                if overBudget() { break }
                guard let identity = claudeIdentity(inConfigDir: dir.path),
                      let key = claudeIdentityKey(identity),
                      key != defaultClaude
                else {
                    defaultRoots.append(dir)
                    continue
                }
                foundDistinct = true
                result.coworkRootsByIdentityKey[key, default: []].append(dir)
                if seenIdentityKeys.insert("claude|\(key)").inserted {
                    result.instances.append(DiscoveredProviderInstance(
                        baseProviderID: "claude",
                        kind: .claudeDesktop,
                        anchorPath: nil,
                        keychainLiteral: nil,
                        desktopOrganization: identity.organizationUuid?.nilIfEmpty?.lowercased(),
                        identityKey: key,
                        identityLabel: claudeIdentityLabel(identity)
                    ))
                }
            }
            if foundDistinct {
                result.defaultClaudeCoworkRoots = defaultRoots
                let partition = result.coworkRootsByIdentityKey
                    .map { "\(ProviderInstanceID.hash8($0.key))=\($0.value.count)" }
                    .sorted().joined(separator: ", ")
                result.notes.append("cowork partition: default=\(defaultRoots.count) dirs, \(partition)")
            }
        }

        let elapsed = Int(now().timeIntervalSince(started) * 1000)
        if result.instances.isEmpty {
            AppLog.info(.config, "provider-instance discovery: no extra logins (\(elapsed)ms)")
        } else {
            let summary = result.instances
                .map { "\($0.baseProviderID)/\($0.kind.rawValue)" }
                .joined(separator: ", ")
            AppLog.info(.config, "provider-instance discovery: \(result.instances.count) extra login(s) [\(summary)] (\(elapsed)ms)")
        }
        // The support trail (bounded): every near-miss and fold, so "my account didn't show up" is
        // answerable from a default log without a debug build.
        for note in result.notes.prefix(30) {
            AppLog.info(.config, "discovery: \(note)")
        }
        if result.notes.count > 30 {
            AppLog.info(.config, "discovery: … and \(result.notes.count - 30) more notes")
        }
        return result
    }

    // MARK: - Candidates

    /// Dot-dirs at `~` plus dirs under `~/.config` — bounded, never temp dirs or project trees.
    private func candidateDirectories(home: URL) -> [URL] {
        var candidates: [URL] = []
        candidates += subdirectories(of: home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += subdirectories(of: home.appendingPathComponent(".config"))
        return candidates.sorted { $0.path < $1.path }
    }

    private func subdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    // MARK: - Claude

    /// The identity file sits inside a custom config dir, but next to (not inside) the default
    /// `~/.claude` — Claude Code keeps the default's state at `~/.claude.json`.
    private func claudeIdentityPath(forConfigDir dir: String) -> String {
        let expanded = expandHome(dir)
        let defaultDir = homeDirectory().appendingPathComponent(".claude").path
        if canonical(expanded) == canonical(defaultDir) {
            return homeDirectory().appendingPathComponent(".claude.json").path
        }
        return expanded + "/.claude.json"
    }

    private func claudeIdentity(inConfigDir dir: String) -> ClaudeIdentity.OAuthAccount? {
        let path = claudeIdentityPath(forConfigDir: dir)
        guard let text = try? files.readTextIfPresent(path),
              let parsed = try? JSONDecoder().decode(ClaudeIdentity.self, from: Data(text.utf8))
        else { return nil }
        return parsed.oauthAccount
    }

    private func defaultClaudeConfigDirs() -> [String] {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let dirs = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !dirs.isEmpty { return dirs }
        }
        return [homeDirectory().appendingPathComponent(".claude").path]
    }

    private func defaultClaudeIdentityKey() -> String? {
        for dir in defaultClaudeConfigDirs() {
            if let identity = claudeIdentity(inConfigDir: dir),
               let key = claudeIdentityKey(identity) {
                return key
            }
        }
        return nil
    }

    private func claudeCandidate(
        at url: URL,
        defaultIdentityKey: String?,
        notes: inout [String]
    ) -> DiscoveredProviderInstance? {
        // Pre-gate: only dirs that carry an identity file at all enter the trail — everything else
        // is a random dot-dir and stays out of the log.
        guard let identityText = try? files.readTextIfPresent(claudeIdentityPath(forConfigDir: url.path)) else {
            return nil
        }
        guard let parsed = try? JSONDecoder().decode(ClaudeIdentity.self, from: Data(identityText.utf8)),
              let identity = parsed.oauthAccount,
              let key = claudeIdentityKey(identity)
        else {
            notes.append("claude candidate \(url.path): identity file present but unreadable (no oauthAccount/accountUuid) → skipped")
            return nil
        }
        guard key != defaultIdentityKey else {
            notes.append("claude candidate \(url.path): same account as the default card (\(ProviderInstanceID.hash8(key))) → folded")
            return nil
        }

        // Credential shape: the dir's own `.credentials.json`, or its *computed* keychain item. Claude
        // Code hashes the literal CLAUDE_CONFIG_DIR string, so both spellings of this path are probed
        // (attributes only — no secret, no prompt).
        let credentialsPath = url.path + "/.credentials.json"
        let fileBacked = (try? files.readTextIfPresent(credentialsPath))
            .flatMap { ClaudeAuthStore.parseCredentials($0) }?
            .claudeAiOauth?.accessToken?.nilIfEmpty != nil

        var matchedLiteral: String?
        let literals = keychainLiterals(for: url)
        for literal in literals {
            let service = "Claude Code-credentials-\(ProviderInstanceID.hash8(literal))"
            if keychain.hasGenericPassword(service: service, account: nil) {
                matchedLiteral = literal
                break
            }
        }
        guard fileBacked || matchedLiteral != nil else {
            notes.append("claude candidate \(url.path): identity \(ProviderInstanceID.hash8(key)) but no credential (no .credentials.json, no keychain item for \(literals.count) path spellings) → skipped")
            return nil
        }

        notes.append("claude candidate \(url.path): accepted as \(ProviderInstanceID.make(baseProviderID: "claude", identityKey: key)) (\(fileBacked ? "file" : "keychain") credential)")
        return DiscoveredProviderInstance(
            baseProviderID: "claude",
            kind: .claudeConfigDir,
            anchorPath: url.path,
            keychainLiteral: matchedLiteral ?? url.path,
            identityKey: key,
            identityLabel: claudeIdentityLabel(identity)
        )
    }

    /// The literal strings a user could have exported as `CLAUDE_CONFIG_DIR` for this dir. Claude Code
    /// hashes the env value as typed, so every plausible spelling must be probed: the enumerated path,
    /// its symlink-resolved form, the same suffix re-anchored on each spelling of the home dir
    /// (`/var` vs `/private/var`, symlinked homes), and the `~/`-abbreviation of each.
    private func keychainLiterals(for url: URL) -> [String] {
        let home = homeDirectory()
        let homePaths = Array(Set([home.path, home.resolvingSymlinksInPath().path]))
        var candidates = [url.path, url.resolvingSymlinksInPath().path]
        for candidate in candidates {
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                let suffix = candidate.dropFirst(homePath.count)
                candidates += homePaths.map { $0 + suffix }
            }
        }
        var literals: [String] = []
        for candidate in candidates {
            literals.append(candidate)
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                literals.append("~" + candidate.dropFirst(homePath.count))
            }
        }
        var seen = Set<String>()
        return literals.filter { seen.insert($0).inserted }
    }

    // MARK: - claude-swap (cswap) vault

    /// The swap tool's backup roots: legacy `~/.claude-swap-backup` (macOS/Windows) and the XDG data
    /// dir it uses elsewhere. First root with slot configs wins.
    private func claudeSwapBackupRoots() -> [URL] {
        let home = homeDirectory()
        return [
            home.appendingPathComponent(".claude-swap-backup"),
            home.appendingPathComponent(".local/share/claude-swap")
        ]
    }

    /// Parked cswap slots as instance findings. Identity comes from the vault's own per-slot config
    /// backup (`configs/.claude-config-<N>-<email>.json` — a full `.claude.json` copy, org included);
    /// the credential address is the vault's keychain item (`claude-swap` / `account-<N>-<email>`)
    /// with an `.enc` file fallback. All file reads; nothing here can prompt.
    private func claudeSwapSlots(defaultIdentityKey: String?, notes: inout [String]) -> [DiscoveredProviderInstance] {
        for root in claudeSwapBackupRoots() {
            let configsDir = root.appendingPathComponent("configs")
            let configs = (try? FileManager.default.contentsOfDirectory(
                at: configsDir, includingPropertiesForKeys: nil, options: []
            )) ?? []
            guard !configs.isEmpty else { continue }
            let activeSlot = claudeSwapActiveSlot(root: root)
            notes.append("cswap vault \(root.path): \(configs.count) slot config(s), active=\(activeSlot ?? "unknown")")

            var findings: [DiscoveredProviderInstance] = []
            for file in configs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.lastPathComponent
                guard name.hasPrefix(".claude-config-"), name.hasSuffix(".json") else { continue }
                let core = name.dropFirst(".claude-config-".count).dropLast(".json".count)
                guard let dash = core.firstIndex(of: "-") else { continue }
                let slot = String(core[..<dash])
                let email = String(core[core.index(after: dash)...])
                // The active slot IS the default card; only parked slots become instances.
                guard Int(slot) != nil else { continue }
                guard slot != activeSlot else {
                    notes.append("cswap slot \(slot): active → it IS the default card, not an instance")
                    continue
                }
                guard let text = try? files.readTextIfPresent(file.path),
                      let parsed = try? JSONDecoder().decode(ClaudeIdentity.self, from: Data(text.utf8)),
                      let account = parsed.oauthAccount,
                      let key = claudeIdentityKey(account)
                else {
                    notes.append("cswap slot \(slot): config backup unreadable (no oauthAccount) → skipped")
                    continue
                }
                guard key != defaultIdentityKey else {
                    notes.append("cswap slot \(slot): same account as the default card (\(ProviderInstanceID.hash8(key))) → folded")
                    continue
                }
                notes.append("cswap slot \(slot): parked → instance \(ProviderInstanceID.make(baseProviderID: "claude", identityKey: key))")
                findings.append(DiscoveredProviderInstance(
                    baseProviderID: "claude",
                    kind: .claudeSwapSlot,
                    anchorPath: root.path,
                    keychainLiteral: nil,
                    desktopOrganization: account.organizationUuid?.nilIfEmpty?.lowercased(),
                    swapAccountName: "account-\(slot)-\(email)",
                    identityKey: key,
                    identityLabel: claudeIdentityLabel(account)
                ))
            }
            if !findings.isEmpty { return findings }
        }
        return []
    }

    private func claudeSwapActiveSlot(root: URL) -> String? {
        struct SequenceFile: Codable { var activeAccountNumber: Int? }
        guard let text = try? files.readTextIfPresent(root.appendingPathComponent("sequence.json").path),
              let parsed = try? JSONDecoder().decode(SequenceFile.self, from: Data(text.utf8))
        else { return nil }
        return parsed.activeAccountNumber.map(String.init)
    }

    // MARK: - Codex

    private func defaultCodexHomes() -> [String] {
        if let raw = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let homes = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !homes.isEmpty { return homes }
        }
        let home = homeDirectory()
        return [
            home.appendingPathComponent(".config/codex").path,
            home.appendingPathComponent(".codex").path
        ]
    }

    private func defaultCodexIdentityKeys() -> Set<String> {
        var keys = Set<String>()
        for home in defaultCodexHomes() {
            if let key = codexIdentity(inHome: expandHome(home))?.key {
                keys.insert(key)
            }
        }
        return keys
    }

    private func codexIdentity(inHome path: String) -> (key: String, email: String?)? {
        guard let text = try? files.readTextIfPresent(path + "/auth.json"),
              let auth = CodexAuthStore.parseAuth(text),
              auth.tokens?.accessToken?.nilIfEmpty != nil
        else { return nil }
        let email = auth.tokens?.idToken
            .flatMap { ProviderParse.jwtPayload($0)?["email"] as? String }?
            .nilIfEmpty
        if let accountID = auth.tokens?.accountID?.nilIfEmpty {
            return (accountID, email)
        }
        // No account id in the file — key on the canonical home so the instance id stays stable.
        return ("codex-home:\(canonical(path))", email)
    }

    private func codexCandidate(
        at url: URL,
        defaultIdentityKeys: Set<String>,
        notes: inout [String]
    ) -> DiscoveredProviderInstance? {
        if let identity = codexIdentity(inHome: url.path) {
            guard !defaultIdentityKeys.contains(identity.key) else {
                notes.append("codex candidate \(url.path): same account as the default card (\(ProviderInstanceID.hash8(identity.key))) → folded")
                return nil
            }
            notes.append("codex candidate \(url.path): accepted as \(ProviderInstanceID.make(baseProviderID: "codex", identityKey: identity.key)) (auth.json)")
            return DiscoveredProviderInstance(
                baseProviderID: "codex",
                kind: .codexHome,
                anchorPath: url.path,
                keychainLiteral: nil,
                identityKey: identity.key,
                identityLabel: identity.email
            )
        }

        if files.exists(url.path + "/auth.json") {
            notes.append("codex candidate \(url.path): auth.json present but not Codex-shaped (no usable tokens) → skipped")
            return nil
        }

        // Keyring mode deletes `auth.json` but the home keeps its shape (config/sessions) and its
        // keychain item name is computable from the canonical home path. Identity needs the secret, so
        // it stays path-keyed until the first refresh; the attributes probe never prompts.
        let looksLikeCodexHome = files.exists(url.path + "/config.toml")
            || files.exists(url.path + "/sessions")
        guard looksLikeCodexHome else { return nil }
        guard keychain.hasGenericPassword(
            service: CodexAuthStore.keychainService,
            account: CodexAuthStore.keychainAccountName(forHome: url.path)
        ) else {
            notes.append("codex candidate \(url.path): codex-shaped dir but no auth.json and no keychain item for its home hash → skipped")
            return nil
        }
        notes.append("codex candidate \(url.path): accepted (keyring-mode home, identity pending first refresh)")
        return DiscoveredProviderInstance(
            baseProviderID: "codex",
            kind: .codexHome,
            anchorPath: url.path,
            keychainLiteral: nil,
            identityKey: "codex-home:\(canonical(url.path))",
            identityLabel: nil
        )
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandHome(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
