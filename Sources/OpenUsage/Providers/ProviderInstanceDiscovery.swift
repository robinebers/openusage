import Foundation

/// Launch-time auto-discovery of extra Claude/Codex logins ("provider instances").
///
/// Runs synchronously in `AppContainer.init` before the registry is built, under a small time budget,
/// and reads **no keychain secrets** — credential presence is checked from file existence and
/// attributes-only keychain probes, so discovery can never raise a macOS permission dialog or block
/// launch (the #987 lesson). A keyring-only Codex home whose account binding is unknown stays hidden
/// for this launch; a retained post-launch task performs one account-scoped read to warm its local
/// identity cache, which may show the normal one-time Keychain prompt without rendering a duplicate.
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
    var codexIdentityCache: (any CodexHomeIdentityCaching)?
    var homeDirectory: () -> URL
    /// Wall-clock budget; on overrun the scan returns what it has (and the next launch resumes).
    var timeBudget: TimeInterval
    var now: () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(attributeProbeTimeout: 0.05),
        codexIdentityCache: (any CodexHomeIdentityCaching)? = nil,
        homeDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        timeBudget: TimeInterval = 0.4,
        now: @escaping () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.codexIdentityCache = codexIdentityCache
        self.homeDirectory = homeDirectory
        self.timeBudget = timeBudget
        self.now = now
    }

    struct Result {
        var instances: [DiscoveredProviderInstance] = []
        /// Additional Claude log roots grouped by account (sibling config homes plus Cowork
        /// sandboxes). The preferred credential source still owns and scans its primary root; this
        /// map preserves every other same-account source. The legacy property name is retained because
        /// Cowork was the first multi-root source.
        var coworkRootsByIdentityKey: [String: [URL]] = [:]
        /// Codex homes grouped by a verified account identity. `ProviderCatalog` converts this to a
        /// home→siblings lookup so the credential stays pinned to one selected home while its scanner
        /// includes every same-account source.
        var codexLogRootsByIdentityKey: [String: [URL]] = [:]
        /// Findings folded into another card because their identity matched the current default or a
        /// previously discovered source. They never create a new card, but an already-persisted
        /// anchored record may need this current identity during reconciliation after an in-place
        /// re-login; `AppContainer` forwards only findings whose anchor already has a record.
        var foldedInstancesForReconciliation: [DiscoveredProviderInstance] = []
        /// Codex keyring homes whose item exists but whose cached account binding is absent or stale.
        /// Their records are suppressed for this launch; `AppContainer` performs one retained,
        /// account-scoped runtime read to warm the fingerprint-bound cache for the next launch.
        var unverifiedCodexKeyringHomes: Set<String> = []
        /// Readable identities at homes currently assigned to a default card. These homes are excluded
        /// from ordinary instance discovery, but an existing anchored record still needs the update
        /// when a custom home becomes `CODEX_HOME`/`CLAUDE_CONFIG_DIR` or is re-logged in there.
        var defaultAnchoredInstancesForReconciliation: [DiscoveredProviderInstance] = []
        /// Set only when a distinct-account Cowork login exists: the default card's partition of the
        /// Cowork walk. `nil` = no partition, keep the scanner's built-in walk byte-identical.
        var defaultClaudeCoworkRoots: [URL]?
        /// When the scanner's implicit XDG and `~/.claude` roots name different accounts, pin the
        /// default card to the root ClaudeAuthStore can actually authenticate. The other root can then
        /// become an ordinary instance instead of having its logs published under the default identity.
        var defaultClaudeLogRoots: [URL]?
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
        /// Swap machines only: the account-activity timeline from cswap's own switch log, used to
        /// attribute the SHARED home's spend logs per account (see `ClaudeSwapTimeline`).
        var claudeSwapTimeline: ClaudeSwapTimeline?
        /// The default card's config dirs (env override respected) — the shared log roots that swap
        /// cards partition by time.
        var claudeSharedHomeRoots: [URL] = []
        /// Bases whose default login has a credential footprint but no readable identity THIS launch.
        /// Nothing account-scoped is trustworthy for them: no new candidates were accepted, and
        /// persisted records must not build runtimes either — any record could be the very account
        /// the default card currently shows.
        var basesWithUnreadableDefault: Set<String> = []
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
        let defaultClaudeFindings = defaultClaudeIdentityFindings()
        let defaultClaudeCredentialHome = defaultClaudeCredentialHome()
        let credentialHomeFinding = defaultClaudeCredentialHome.flatMap { credentialHome in
            let canonicalCredentialHome = canonical(credentialHome)
            return defaultClaudeFindings.first {
                $0.anchorPath.map(canonical) == canonicalCredentialHome
            }
        }
        // Preserve the historical XDG-only setup when it is the sole readable default source. If XDG
        // and the standard credential home disagree, the credential home wins instead.
        let defaultClaudeFinding = credentialHomeFinding
            ?? (Set(defaultClaudeFindings.map(\.identityKey)).count == 1
                ? defaultClaudeFindings.first
                : nil)
        let defaultClaude = defaultClaudeFinding?.identityKey
        let defaultClaudeIdentities = Set(defaultClaudeFindings.map(\.identityKey))
        let claudeDefaultRootsDisagree = defaultClaudeIdentities.count > 1
        if claudeDefaultRootsDisagree, let defaultClaudeCredentialHome {
            result.defaultClaudeLogRoots = [URL(fileURLWithPath: expandHome(defaultClaudeCredentialHome))]
            result.notes.append("claude: default log roots name different accounts → pinning the default scanner to its credential home")
        }
        result.defaultAnchoredInstancesForReconciliation.append(contentsOf: defaultClaudeFindings)
        let defaultCodexResolution = defaultCodexIdentityKeysByHome(
            unverifiedKeyringHomes: &result.unverifiedCodexKeyringHomes
        )
        let defaultCodexByHome = defaultCodexResolution.identities
        let defaultCodex = Set(defaultCodexByHome.values)
        if let defaultClaude { result.defaultIdentityKeys["claude"] = [defaultClaude] }
        if !defaultCodex.isEmpty { result.defaultIdentityKeys["codex"] = defaultCodex }
        for (path, identityKey) in defaultCodexByHome {
            result.defaultAnchoredInstancesForReconciliation.append(DiscoveredProviderInstance(
                baseProviderID: "codex",
                kind: .codexHome,
                anchorPath: path,
                keychainLiteral: nil,
                identityKey: identityKey,
                identityLabel: nil
            ))
            appendUniqueCodexRoot(
                URL(fileURLWithPath: path),
                identityKey: identityKey,
                to: &result
            )
        }
        let excludedClaudePaths = if claudeDefaultRootsDisagree,
                                     let defaultClaudeCredentialHome {
            [defaultClaudeCredentialHome]
        } else {
            defaultClaudeConfigDirs()
        }
        let excludedPaths = Set((excludedClaudePaths + defaultCodexHomes()).map { canonical($0) })

        let claudeDefaultHash = defaultClaude.map(ProviderInstanceID.hash8) ?? "none"
        let codexDefaultHashes = defaultCodex.map(ProviderInstanceID.hash8).sorted().joined(separator: ",")
        result.notes.append("default identities: claude=\(claudeDefaultHash) codex=[\(codexDefaultHashes)]")

        // Same-account folding needs the default card's identity. When the default login clearly
        // EXISTS (credential footprint) but can't be named, accepting candidates could show the same
        // account twice — skip them for this launch instead (folding resumes once identity is
        // readable). A machine with no default login at all keeps accepting: there is nothing to
        // duplicate, and a custom-dir-only login should still get its card.
        let claudeCandidatesAllowed = defaultClaude != nil || !defaultClaudeCredentialFootprint()
        if !claudeCandidatesAllowed {
            result.basesWithUnreadableDefault.insert("claude")
            result.notes.append("claude: default login present but its identity is unreadable → skipping extra-account candidates this launch")
        }
        let codexCandidatesAllowed = !defaultCodexResolution.hasUnresolvedFootprint
            && (!defaultCodex.isEmpty || !defaultCodexCredentialFootprint())
        if !codexCandidatesAllowed {
            result.basesWithUnreadableDefault.insert("codex")
            result.notes.append("codex: default login present but its identity is unreadable → skipping extra-account candidates this launch")
        }

        for candidate in candidateDirectories(home: home) {
            guard !overBudget() else { break }
            let canonicalPath = canonical(candidate.path)
            guard !excludedPaths.contains(canonicalPath) else { continue }

            if claudeCandidatesAllowed,
               let finding = claudeCandidate(at: candidate, notes: &result.notes) {
                if finding.identityKey == defaultClaude {
                    appendUniqueClaudeRoot(candidate, identityKey: finding.identityKey, to: &result)
                    result.foldedInstancesForReconciliation.append(finding)
                    result.notes.append("claude candidate \(ProviderInstanceID.logPath(candidate.path)): same account as the default card (\(ProviderInstanceID.hash8(finding.identityKey))) → folded, usage root retained")
                } else if seenIdentityKeys.insert("claude|\(finding.identityKey)").inserted {
                    result.instances.append(finding)
                } else {
                    appendUniqueClaudeRoot(candidate, identityKey: finding.identityKey, to: &result)
                    result.foldedInstancesForReconciliation.append(finding)
                    result.notes.append("claude candidate \(ProviderInstanceID.logPath(candidate.path)): identity already has a card → retained as an additional usage root")
                }
            }
            if codexCandidatesAllowed,
               let finding = codexCandidate(
                   at: candidate,
                   unverifiedKeyringHomes: &result.unverifiedCodexKeyringHomes,
                   notes: &result.notes
               ) {
                if !ProviderInstanceID.isPathDerivedKey(finding.identityKey) {
                    appendUniqueCodexRoot(candidate, identityKey: finding.identityKey, to: &result)
                }
                if defaultCodex.contains(finding.identityKey) {
                    result.foldedInstancesForReconciliation.append(finding)
                    result.notes.append("codex candidate \(ProviderInstanceID.logPath(candidate.path)): same account as the default card (\(ProviderInstanceID.hash8(finding.identityKey))) → folded, usage root retained")
                } else if seenIdentityKeys.insert("codex|\(finding.identityKey)").inserted {
                    result.instances.append(finding)
                } else {
                    result.foldedInstancesForReconciliation.append(finding)
                    result.notes.append("codex candidate \(ProviderInstanceID.logPath(candidate.path)): identity already has a card → retained as an additional usage root")
                }
            }
        }

        // claude-swap (cswap) vault: each PARKED slot's identity comes from the tool's own per-slot
        // config backup — the active slot is exactly what the default card shows, so it is never an
        // instance. Runs before the Cowork walk so a same-account Cowork finding upgrades to the
        // swap-vault credential source instead of the borrowed Desktop token. Gated on the same
        // unreadable-default guard as dot-dir candidates: with a footprint-but-nameless default, slot
        // folding would be blind AND the timeline's default-card filter couldn't be built — the
        // unfiltered default scanner next to filtered slot cards would double-count the shared home.
        if !overBudget(), claudeCandidatesAllowed {
            let swap = claudeSwapContext(
                defaultIdentityKey: defaultClaude,
                referenceDate: started,
                notes: &result.notes
            )
            for finding in swap.findings {
                if seenIdentityKeys.insert("claude|\(finding.identityKey)").inserted {
                    result.instances.append(finding)
                    continue
                }

                // The vault is the preferred credential source for a parked slot because cswap owns
                // that account's rotation lifecycle. Keep any already-discovered config home as an
                // additional unfiltered log root instead of dropping either source.
                guard let index = result.instances.firstIndex(where: {
                    $0.baseProviderID == "claude" && $0.identityKey == finding.identityKey
                }) else { continue }
                let previous = result.instances[index]
                if previous.kind == .claudeConfigDir, let anchor = previous.anchorPath {
                    appendUniqueClaudeRoot(URL(fileURLWithPath: anchor), identityKey: finding.identityKey, to: &result)
                }
                result.instances[index] = finding
                result.notes.append("cswap slot: existing identity upgraded to the vault credential source; prior config roots retained for usage")
            }
            result.claudeSwapTimeline = swap.timeline
            if swap.timeline != nil {
                result.claudeSharedHomeRoots = (result.defaultClaudeLogRoots?.map(\.path)
                    ?? defaultClaudeConfigDirs())
                    .map { URL(fileURLWithPath: expandHome($0)) }
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
                    guard let organization = identity.organizationUuid?.nilIfEmpty?.lowercased() else {
                        result.notes.append("cowork candidate \(ProviderInstanceID.logPath(dir.path)): distinct identity has no organization pin → skipped Desktop-backed card")
                        continue
                    }
                    result.instances.append(DiscoveredProviderInstance(
                        baseProviderID: "claude",
                        kind: .claudeDesktop,
                        anchorPath: nil,
                        keychainLiteral: nil,
                        desktopOrganization: organization,
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

        if overBudget() {
            result.basesWithUnreadableDefault.formUnion(["claude", "codex"])
            result.notes.append("discovery budget expired before every source was scanned → suppressing account instances this launch")
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

    private func appendUniqueClaudeRoot(_ root: URL, identityKey: String, to result: inout Result) {
        let canonicalRoot = canonical(root.path)
        let alreadyPresent = result.coworkRootsByIdentityKey[identityKey, default: []]
            .contains { canonical($0.path) == canonicalRoot }
        if !alreadyPresent {
            result.coworkRootsByIdentityKey[identityKey, default: []].append(root)
        }
    }

    private func appendUniqueCodexRoot(_ root: URL, identityKey: String, to result: inout Result) {
        let canonicalRoot = canonical(root.path)
        let alreadyPresent = result.codexLogRootsByIdentityKey[identityKey, default: []]
            .contains { canonical($0.path) == canonicalRoot }
        if !alreadyPresent {
            result.codexLogRootsByIdentityKey[identityKey, default: []].append(root)
        }
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
        // Mirror the spend scanner's default resolution exactly ($XDG_CONFIG_HOME/claude first, then
        // ~/.claude) — these dirs are the exclusion set, the default-identity source, AND the shared
        // log roots on swap machines, so dropping the XDG variant would lose its logs from the
        // timeline-attributed scan.
        let home = homeDirectory()
        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { expandHome($0) }
            ?? home.appendingPathComponent(".config").path
        return [xdg + "/claude", home.appendingPathComponent(".claude").path]
    }

    /// The home standard Claude auth can actually read. XDG roots are valid log sources, but without
    /// `CLAUDE_CONFIG_DIR` the credential store still targets `~/.claude`.
    private func defaultClaudeCredentialHome() -> String? {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let dirs = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // ClaudeAuthStore treats the environment value as one credential path. A comma-separated
            // scanner-only list cannot be assigned one safe account identity.
            guard dirs.count == 1 else { return nil }
            return dirs[0]
        }
        return homeDirectory().appendingPathComponent(".claude").path
    }

    /// Current default identity, exposed to the long-lived default runtime so an in-process cswap
    /// change can be refused until the launch-time registry is rebuilt.
    func defaultClaudeIdentityKey() -> String? {
        if let home = defaultClaudeCredentialHome(),
           let identity = claudeIdentity(inConfigDir: home),
           let key = claudeIdentityKey(identity) {
            return key
        }
        let keys = defaultClaudeIdentityFindings().map(\.identityKey)
        return Set(keys).count == 1 ? keys.first : nil
    }

    private func defaultClaudeIdentityFindings() -> [DiscoveredProviderInstance] {
        defaultClaudeConfigDirs().compactMap { dir in
            guard let identity = claudeIdentity(inConfigDir: dir),
                  let key = claudeIdentityKey(identity)
            else { return nil }
            return DiscoveredProviderInstance(
                baseProviderID: "claude",
                kind: .claudeConfigDir,
                anchorPath: expandHome(dir),
                keychainLiteral: dir,
                desktopOrganization: identity.organizationUuid?.nilIfEmpty?.lowercased(),
                identityKey: key,
                identityLabel: claudeIdentityLabel(identity)
            )
        }
    }

    /// Whether the DEFAULT Claude login leaves any credential footprint — file or (attributes-only)
    /// keychain — used solely to decide if a nil default identity means "no login" (safe to accept
    /// candidates) or "login we can't name" (skip candidates; folding would be blind).
    private func defaultClaudeCredentialFootprint() -> Bool {
        if keychain.hasGenericPassword(
            service: ClaudeAuthStore.baseKeychainServiceName(environment: environment),
            account: nil
        ) { return true }
        for dir in defaultClaudeConfigDirs() {
            if files.exists(expandHome(dir) + "/.credentials.json") { return true }
            if keychain.hasGenericPassword(
                service: ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: dir, environment: environment),
                account: nil
            ) { return true }
        }
        return false
    }

    private func claudeCandidate(
        at url: URL,
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
            notes.append("claude candidate \(ProviderInstanceID.logPath(url.path)): identity file present but unreadable (no oauthAccount/accountUuid) → skipped")
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
            // Same construction the scoped store reads with — including the non-prod OAuth env
            // suffix — so discovery can never probe one service name while refresh targets another.
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: literal,
                environment: environment
            )
            if keychain.hasGenericPassword(service: service, account: nil) {
                matchedLiteral = literal
                break
            }
        }
        guard fileBacked || matchedLiteral != nil else {
            notes.append("claude candidate \(ProviderInstanceID.logPath(url.path)): identity \(ProviderInstanceID.hash8(key)) but no credential (no .credentials.json, no keychain item for \(literals.count) path spellings) → skipped")
            return nil
        }

        notes.append("claude candidate \(ProviderInstanceID.logPath(url.path)): accepted as \(ProviderInstanceID.make(baseProviderID: "claude", identityKey: key)) (\(fileBacked ? "file" : "keychain") credential)")
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

    private struct ClaudeSwapSlot {
        var number: String
        var email: String
        var account: ClaudeIdentity.OAuthAccount
        var identityKey: String
    }

    /// Parked cswap slots as instance findings. Identity comes from the vault's own per-slot config
    /// backup (`configs/.claude-config-<N>-<email>.json` — a full `.claude.json` copy, org included);
    /// the credential address is the vault's keychain item (`claude-swap` / `account-<N>-<email>`)
    /// with an `.enc` file fallback. All file reads; nothing here can prompt.
    private func claudeSwapContext(
        defaultIdentityKey: String?,
        referenceDate: Date,
        notes: inout [String]
    ) -> (findings: [DiscoveredProviderInstance], timeline: ClaudeSwapTimeline?) {
        for root in claudeSwapBackupRoots() {
            let configsDir = root.appendingPathComponent("configs")
            let configs = (try? FileManager.default.contentsOfDirectory(
                at: configsDir, includingPropertiesForKeys: nil, options: []
            )) ?? []
            guard !configs.isEmpty else { continue }

            var slots: [ClaudeSwapSlot] = []
            var slotIdentities: [String: String] = [:]
            for file in configs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.lastPathComponent
                guard name.hasPrefix(".claude-config-"), name.hasSuffix(".json") else { continue }
                let core = name.dropFirst(".claude-config-".count).dropLast(".json".count)
                guard let dash = core.firstIndex(of: "-") else { continue }
                let slot = String(core[..<dash])
                let email = String(core[core.index(after: dash)...])
                guard Int(slot) != nil else { continue }
                guard let text = try? files.readTextIfPresent(file.path),
                      let parsed = try? JSONDecoder().decode(ClaudeIdentity.self, from: Data(text.utf8)),
                      let account = parsed.oauthAccount,
                      let key = claudeIdentityKey(account)
                else {
                    notes.append("cswap slot \(slot): config backup unreadable (no oauthAccount) → skipped")
                    continue
                }
                // Every slot's identity feeds the timeline — including the active one, whose periods
                // belong to the default card.
                slotIdentities[slot] = key
                slots.append(ClaudeSwapSlot(number: slot, email: email, account: account, identityKey: key))
            }

            // `sequence.json` is transaction bookkeeping, not authoritative live state: cswap can
            // leave it one step behind after an interrupted switch. Resolve the active slot from the
            // identity in the live default `.claude.json`; use sequence only to disambiguate duplicate
            // vault entries that both name that same live identity.
            let sequenceSlot = claudeSwapSequenceSlot(root: root)
            let liveMatches = defaultIdentityKey.map { defaultKey in
                slots.filter { $0.identityKey == defaultKey }.map(\.number)
            } ?? []
            let activeSlot: String?
            if liveMatches.count == 1 {
                let resolvedSlot = liveMatches[0]
                activeSlot = resolvedSlot
                if let sequenceSlot, sequenceSlot != resolvedSlot {
                    notes.append("cswap sequence=\(sequenceSlot) disagrees with the live default identity → using slot \(resolvedSlot)")
                }
            } else if liveMatches.count > 1,
                      let sequenceSlot,
                      liveMatches.contains(sequenceSlot) {
                activeSlot = sequenceSlot
                notes.append("cswap live identity appears in multiple slots → sequence safely disambiguated slot \(sequenceSlot)")
            } else {
                activeSlot = nil
                if let sequenceSlot {
                    notes.append("cswap sequence=\(sequenceSlot) is not consistent with a unique live default identity → ignored")
                }
            }
            notes.append("cswap vault \(ProviderInstanceID.logPath(root.path)): \(slots.count) readable slot config(s), active=\(activeSlot ?? "unknown")")

            var findings: [DiscoveredProviderInstance] = []
            for slot in slots {
                // The active slot IS the default card; only parked slots become instances.
                guard slot.number != activeSlot else {
                    notes.append("cswap slot \(slot.number): active → it IS the default card, not an instance")
                    continue
                }
                guard slot.identityKey != defaultIdentityKey else {
                    notes.append("cswap slot \(slot.number): same account as the default card (\(ProviderInstanceID.hash8(slot.identityKey))) → folded")
                    continue
                }
                notes.append("cswap slot \(slot.number): parked → instance \(ProviderInstanceID.make(baseProviderID: "claude", identityKey: slot.identityKey))")
                findings.append(DiscoveredProviderInstance(
                    baseProviderID: "claude",
                    kind: .claudeSwapSlot,
                    anchorPath: root.path,
                    keychainLiteral: nil,
                    desktopOrganization: slot.account.organizationUuid?.nilIfEmpty?.lowercased(),
                    swapAccountName: "account-\(slot.number)-\(slot.email)",
                    identityKey: slot.identityKey,
                    identityLabel: claudeIdentityLabel(slot.account)
                ))
            }

            // Read the rotating history oldest → newest. The current file can contain no switch at all
            // immediately after rotation, while the event needed for attribution lives in `.1`/`.2`.
            // Presence of `.3` means the fixed archive set may have dropped earlier history, so the
            // parser must not extend the oldest retained account to distant-past usage.
            var timeline: ClaudeSwapTimeline?
            if !slotIdentities.isEmpty,
               let history = claudeSwapLogHistory(root: root, notes: &notes) {
                timeline = ClaudeSwapTimeline.parse(
                    logText: history.text,
                    slotIdentities: slotIdentities,
                    retentionIsComplete: history.retentionIsComplete
                )
                if let currentOwner = timeline?.identityKey(at: referenceDate),
                   !currentOwner.isEmpty,
                   let defaultIdentityKey,
                   currentOwner != defaultIdentityKey {
                    timeline = nil
                    notes.append("cswap timeline: newest retained switch disagrees with the live default identity → disabled for this launch")
                }
                if let timeline {
                    notes.append("cswap timeline: \(timeline.periods.count) period(s) from \(history.fileCount) retained log file(s) → per-account spend attribution active")
                } else {
                    notes.append("cswap timeline: no parseable switch events → shared-home spend stays on the default card")
                }
            }
            return (findings, timeline)
        }
        return ([], nil)
    }

    private func claudeSwapSequenceSlot(root: URL) -> String? {
        struct SequenceFile: Codable { var activeAccountNumber: Int? }
        guard let text = try? files.readTextIfPresent(root.appendingPathComponent("sequence.json").path),
              let parsed = try? JSONDecoder().decode(SequenceFile.self, from: Data(text.utf8))
        else { return nil }
        return parsed.activeAccountNumber.map(String.init)
    }

    private func claudeSwapLogHistory(
        root: URL,
        notes: inout [String]
    ) -> (text: String, retentionIsComplete: Bool, fileCount: Int)? {
        let names = ["claude-swap.log.3", "claude-swap.log.2", "claude-swap.log.1", "claude-swap.log"]
        var retained: [(name: String, text: String)] = []
        var everyPresentFileReadable = true

        for name in names {
            let path = root.appendingPathComponent(name).path
            guard files.exists(path) else { continue }
            do {
                guard let text = try files.readTextIfPresent(path) else {
                    everyPresentFileReadable = false
                    continue
                }
                retained.append((name, text))
            } catch {
                everyPresentFileReadable = false
                notes.append("cswap timeline: retained log \(name) unreadable → older attribution will stay on the default card")
            }
        }
        guard !retained.isEmpty else { return nil }

        let retainedNames = Set(retained.map(\.name))
        let currentPresent = retainedNames.contains("claude-swap.log")
        let archivesContiguous: Bool
        if retainedNames.contains("claude-swap.log.2") {
            archivesContiguous = retainedNames.contains("claude-swap.log.1")
        } else {
            archivesContiguous = true
        }
        // With three backups configured, `.3` is the point at which an older generation may already
        // have been evicted. Treat that boundary conservatively even if this happens to be its first use.
        let retentionIsComplete = everyPresentFileReadable
            && currentPresent
            && archivesContiguous
            && !retainedNames.contains("claude-swap.log.3")
        return (
            retained.map(\.text).joined(separator: "\n"),
            retentionIsComplete,
            retained.count
        )
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

    private func defaultCodexIdentityKeysByHome(
        unverifiedKeyringHomes: inout Set<String>
    ) -> (identities: [String: String], hasUnresolvedFootprint: Bool) {
        var identities: [String: String] = [:]
        var hasUnresolvedFootprint = false
        for home in defaultCodexHomes() {
            let expanded = expandHome(home)
            let fileIdentity = codexIdentity(inHome: expanded)?.key
            let keychainBinding = codexKeychainBinding(inHome: expanded)
            guard keychainBinding.hasItem else {
                if let fileIdentity {
                    identities[canonical(expanded)] = fileIdentity
                    continue
                }
                if files.exists(expanded + "/auth.json") {
                    hasUnresolvedFootprint = true
                }
                continue
            }
            guard let keychainIdentity = keychainBinding.identityKey else {
                hasUnresolvedFootprint = true
                unverifiedKeyringHomes.insert(canonical(expanded))
                continue
            }
            if let fileIdentity, fileIdentity != keychainIdentity {
                // Refresh may authenticate either source (file first, keychain after an auth rejection),
                // so neither identity is safe to publish or use for instance suppression this launch.
                hasUnresolvedFootprint = true
                continue
            }
            identities[canonical(expanded)] = fileIdentity ?? keychainIdentity
        }
        return (identities, hasUnresolvedFootprint)
    }

    /// The Codex twin of `defaultClaudeCredentialFootprint()`: a default home in keyring mode has no
    /// `auth.json` (so no readable identity) but does have its computed keychain item.
    private func defaultCodexCredentialFootprint() -> Bool {
        for home in defaultCodexHomes() {
            let expanded = expandHome(home)
            if files.exists(expanded + "/auth.json") { return true }
            if keychain.hasGenericPassword(
                service: CodexAuthStore.keychainService,
                account: CodexAuthStore.keychainAccountName(forHome: expanded)
            ) { return true }
        }
        return false
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
        return (ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: canonical(path)), email)
    }

    private func codexKeychainBinding(inHome path: String) -> (hasItem: Bool, identityKey: String?) {
        let account = CodexAuthStore.keychainAccountName(forHome: path)
        guard keychain.hasGenericPassword(
            service: CodexAuthStore.keychainService,
            account: account
        ) else { return (false, nil) }
        guard let fingerprint = keychain.genericPasswordAttributeFingerprint(
            service: CodexAuthStore.keychainService,
            account: account
        ) else { return (true, nil) }
        return (
            true,
            codexIdentityCache?.identityKey(
                forHome: path,
                keychainItemFingerprint: fingerprint
            )
        )
    }

    private func codexCandidate(
        at url: URL,
        unverifiedKeyringHomes: inout Set<String>,
        notes: inout [String]
    ) -> DiscoveredProviderInstance? {
        let fileIdentity = codexIdentity(inHome: url.path)
        let authFileExists = files.exists(url.path + "/auth.json")
        let looksLikeCodexHome = authFileExists
            || files.exists(url.path + "/config.toml")
            || files.exists(url.path + "/sessions")
        guard looksLikeCodexHome else { return nil }

        let keychainBinding = codexKeychainBinding(inHome: url.path)
        if !keychainBinding.hasItem {
            guard let fileIdentity else {
                if authFileExists {
                    notes.append("codex candidate \(ProviderInstanceID.logPath(url.path)): auth.json present but not Codex-shaped (no usable tokens) → skipped")
                } else {
                    notes.append("codex candidate \(ProviderInstanceID.logPath(url.path)): codex-shaped dir but no auth.json and no keychain item for its home hash → skipped")
                }
                return nil
            }
            notes.append("codex candidate \(ProviderInstanceID.logPath(url.path)): accepted as \(ProviderInstanceID.make(baseProviderID: "codex", identityKey: fileIdentity.key)) (auth.json)")
            return DiscoveredProviderInstance(
                baseProviderID: "codex",
                kind: .codexHome,
                anchorPath: url.path,
                keychainLiteral: nil,
                identityKey: fileIdentity.key,
                identityLabel: fileIdentity.email
            )
        }

        let sourcesDisagree = if let fileIdentity, let keychainIdentity = keychainBinding.identityKey {
            fileIdentity.key != keychainIdentity
        } else {
            false
        }
        if keychainBinding.identityKey == nil || sourcesDisagree {
            unverifiedKeyringHomes.insert(canonical(url.path))
            let reason = sourcesDisagree ? "file and keyring identities disagree" : "keyring item identity unverified"
            notes.append("codex candidate \(ProviderInstanceID.logPath(url.path)): \(reason) → suppressing its card while identity selection is unsafe")
        } else {
            notes.append("codex candidate \(ProviderInstanceID.logPath(url.path)): accepted (fingerprint-verified keyring identity)")
        }
        let resolvedIdentity = sourcesDisagree
            ? nil
            : fileIdentity?.key ?? keychainBinding.identityKey
        return DiscoveredProviderInstance(
            baseProviderID: "codex",
            kind: .codexHome,
            anchorPath: url.path,
            keychainLiteral: nil,
            identityKey: resolvedIdentity
                ?? ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: canonical(url.path)),
            identityLabel: sourcesDisagree ? nil : fileIdentity?.email
        )
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandHome(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
