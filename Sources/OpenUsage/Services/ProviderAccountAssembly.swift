import Foundation

/// One extra Claude account card to build this launch: a login found on this computer whose account
/// is distinct from the default card's — a custom-config-dir login, or a Claude Desktop (Cowork)
/// login. Cards render only while their source is found (owner decision 4) — a record with no
/// finding this launch simply builds no card.
struct ClaudeAccountCard: Equatable, Sendable {
    /// Where the card's credentials come from (its spend logs are `logRoots`, kept separate —
    /// a Desktop-backed card's logs are Cowork sandboxes, not a credential home).
    enum Credential: Equatable, Sendable {
        /// One custom `CLAUDE_CONFIG_DIR` home; `keychainLiteral` names the dir's keychain item
        /// (see `ClaudeCredentialScope.configDir`).
        case configDir(path: String, keychainLiteral: String)
        /// Claude Desktop's Safe Storage cache, pinned to this org's token
        /// (see `ClaudeCredentialScope.desktopOnly`).
        case desktop(organization: String)
    }

    /// The account's stable record id (`claude@ab12cd34`) — the card id everywhere: layout, cache,
    /// CLI/API matching.
    var id: String
    /// The DERIVED card name (`ProviderAccountRecord.derivedDisplayName`) baked into the launch
    /// `Provider`. Never a rename: renames live only in the account registry and are resolved at
    /// render time, so a baked name can never be a stale copy of one.
    var displayName: String
    var credential: Credential
    /// Every spend-log root the card scans: its config dir(s), plus any Cowork sandboxes this
    /// account produced.
    var logRoots: [URL]
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// scan for extra Claude logins in custom config dirs, reconcile the account registry, and expose
/// what the rest of launch consumes — the per-card identity map (snapshot-cache account stamp) and
/// the extra-card build plan (`ProviderCatalog`). Runs once per launch (app) or per invocation
/// (one-shot CLI); a mid-run swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. A card whose identity didn't
    /// resolve is absent.
    let identityKeysByCard: [String: String]
    /// Extra Claude account cards found on this computer this launch, in stable id order.
    var claudeCards: [ClaudeAccountCard] = []
    /// Same-account custom config dirs discovered for the DEFAULT card's login: extra spend-log
    /// roots for the default scanner, never extra credentials.
    var defaultClaudeExtraLogRoots: [URL] = []
    /// Set only when another account's Cowork sandboxes exist: the default card's partition of the
    /// Cowork walk (that account's sessions must not bleed into the default card's spend). `nil`
    /// keeps the scanner's built-in walk byte-identical.
    var defaultClaudeCoworkRoots: [URL]?

    /// The default Claude account's org UUID, parsed from its identity key (`uuid|org`) — the pin
    /// the default card's Desktop fallback reads under once other Claude cards exist. `nil` when
    /// the default identity is unresolved or the account has no org.
    var defaultClaudeOrganization: String? {
        guard let key = identityKeysByCard["claude"],
              let separator = key.firstIndex(of: "|")
        else { return nil }
        return String(key[key.index(after: separator)...]).nilIfEmpty
    }

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports). The app passes its own
    /// `accountsStore` so the registry the pass reconciles is the same instance the UI observes for
    /// renames; the CLI omits it and gets a throwaway.
    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool
    ) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes), and it reads them through the very same reader the provider auth stores
        // use — `ProcessEnvironmentReader`, which pins identity-relevant keys to the persisted
        // shell-environment snapshot for the whole session, so identity and usage resolve the same
        // homes no matter when the async capture lands. The one unreadable state is a genuinely
        // FIRST Finder/Dock launch: capture still cold and no snapshot persisted yet — a
        // shell-exported home override would be invisible, so that family's read must be skipped
        // rather than misread as "no override". The skip is per family: a family whose home override
        // is already visible in the process environment (a terminal launch, `launchctl setenv`)
        // doesn't need the shell layers at all and still resolves.
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        guard !families.isEmpty else {
            return ProviderAccountAssembly(identityKeysByCard: [:])
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: accountsStore ?? ProviderAccountsStore(defaults: defaults),
            families: families,
            claudeDiscovery: ClaudeConfigDirDiscovery(),
            coworkDiscovery: ClaudeCoworkDiscovery()
        )
    }

    /// The environment variable that relocates each family's default home — the fact whose
    /// invisibility (shell layers unreadable AND not in the process environment) makes that family's
    /// identity read unsafe on a first launch.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// The environment-independent core, separated so tests inject a fixed observer, discovery, and
    /// scratch store. `families` limits the pass to the families whose home facts are readable this
    /// launch (see `make(defaults:waitsForLoginShell:)`); a family left out is simply not observed —
    /// no identity key, no reconciliation, exactly as if the pass never ran for it. `claudeDiscovery`
    /// is skipped alongside the claude family (its exclusion set needs the same home facts).
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        claudeDiscovery: ClaudeConfigDirDiscovery? = nil,
        coworkDiscovery: ClaudeCoworkDiscovery? = nil
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.AccountObservation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.AccountObservation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                // The soak signal for later phases: how often a real login can't name its account.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        // Extra Claude logins in custom config dirs and Cowork sandboxes. Guarded on the default
        // read: when a default login clearly EXISTS but can't be named (`unresolved`), accepting
        // candidates could render the very account the default card shows as a second card — skip
        // them this launch instead. A machine with no default login at all keeps accepting: there
        // is nothing to duplicate, and a custom-dir-only login should still get its card.
        var plannedCards: [PlannedClaudeCard] = []
        var defaultClaudeExtraLogRoots: [URL] = []
        var defaultClaudeCoworkRoots: [URL]?
        let claudeOutcome = outcomes.first { $0.family == "claude" }?.outcome
        var claudeCandidatesAllowed = false
        if let claudeOutcome {
            if case .unresolved = claudeOutcome {
                AppLog.info(.config, "discovery: claude default login present but its identity is unreadable → skipping extra-account candidates this launch")
            } else {
                claudeCandidatesAllowed = true
            }
        }
        if let claudeDiscovery, claudeCandidatesAllowed {
            let defaultKey = identityKeys["claude"]
            let scan = claudeDiscovery.run()
            for note in scan.notes {
                AppLog.info(.config, "discovery: \(note)")
            }
            var order: [String] = []
            var grouped: [String: [ClaudeConfigDirDiscovery.Finding]] = [:]
            for finding in scan.findings {
                if grouped[finding.identityKey] == nil { order.append(finding.identityKey) }
                grouped[finding.identityKey, default: []].append(finding)
            }
            for identityKey in order {
                let findings = grouped[identityKey] ?? []
                let sources = findings.map {
                    ProviderAccountSource(
                        kind: .configDir,
                        anchor: $0.anchorPath,
                        holdsDefaultSource: false,
                        keychainLiteral: $0.keychainLiteral
                    )
                }
                if let defaultKey, sameClaudeAccount(identityKey, defaultKey) {
                    // Same account as the default card: its dirs are extra spend-log roots on
                    // that card, never a second card — duplicate cards are structurally
                    // impossible because identity routes the source to the existing record.
                    defaultClaudeExtraLogRoots += findings.map { URL(fileURLWithPath: $0.anchorPath) }
                    if let index = observations.firstIndex(where: { $0.family == "claude" && $0.identityKey == defaultKey }) {
                        observations[index].sources += sources
                    }
                    AppLog.info(.config, "discovery: \(findings.count) config dir(s) fold onto the default claude card (same account)")
                } else {
                    guard let primary = findings.first else { continue }
                    observations.append(ProviderAccountsStore.AccountObservation(
                        family: "claude",
                        identityKey: identityKey,
                        label: primary.label,
                        sources: sources
                    ))
                    plannedCards.append(PlannedClaudeCard(
                        identityKey: identityKey,
                        credential: .configDir(path: primary.anchorPath, keychainLiteral: primary.keychainLiteral),
                        logRoots: findings.map { URL(fileURLWithPath: $0.anchorPath) }
                    ))
                }
            }
        }

        // Cowork sandboxes: identity comes from each session sandbox's own `.claude.json`.
        // Sandboxes naming the default login (the overwhelmingly common case) stay exactly where
        // they are today — on the default card. Sandboxes naming an account already found in a
        // config dir become that card's extra log roots. A distinct account becomes ONE
        // Desktop-backed card (org-pinned Safe Storage credentials) with its sandboxes as the
        // card's spend logs. The moment any non-default sandbox exists, the default card's walk is
        // partitioned so another account's sessions can't bleed into its spend.
        if let coworkDiscovery, claudeCandidatesAllowed {
            let defaultKey = identityKeys["claude"]
            let scan = coworkDiscovery.run()
            for note in scan.notes {
                AppLog.info(.config, "discovery: \(note)")
            }
            var defaultBucket: [URL] = []
            var order: [String] = []
            var grouped: [String: [ClaudeCoworkDiscovery.Sandbox]] = [:]
            // A truncated walk saw only some sandboxes; routing on it could partition away default
            // spend or miss a non-default sandbox entirely. Skip the pass — the built-in walk stays
            // byte-identical this launch, and the next launch retries.
            for sandbox in scan.truncated ? [] : scan.sandboxes {
                guard let key = sandbox.identityKey,
                      !(defaultKey.map { sameClaudeAccount(key, $0) } ?? false)
                else {
                    // An unidentified or default-account sandbox counts on the default card,
                    // exactly where the built-in walk has always put it.
                    defaultBucket.append(sandbox.root)
                    continue
                }
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(sandbox)
            }
            for identityKey in order {
                let sandboxes = grouped[identityKey] ?? []
                let roots = sandboxes.map(\.root)
                if let index = plannedCards.firstIndex(where: { sameClaudeAccount($0.identityKey, identityKey) }) {
                    // The account already has a card from its config dir; its sandboxes are just
                    // more of its spend logs.
                    plannedCards[index].logRoots += roots
                    AppLog.info(.config, "discovery: \(roots.count) cowork sandbox(es) attach to an existing claude account card as log roots")
                    continue
                }
                guard let organization = sandboxes.compactMap(\.organization).first else {
                    // Desktop caches tokens per org; without the pin the card could only read
                    // Desktop's ACTIVE org, which may be a different account's usage pool.
                    AppLog.info(.config, "discovery: cowork account \(ProviderAccountID.make(family: "claude", identityKey: identityKey)) has no organization pin → skipped Desktop-backed card")
                    continue
                }
                let label = sandboxes.compactMap(\.label).first
                observations.append(ProviderAccountsStore.AccountObservation(
                    family: "claude",
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .desktop, anchor: nil, holdsDefaultSource: false)]
                ))
                plannedCards.append(PlannedClaudeCard(
                    identityKey: identityKey,
                    credential: .desktop(organization: organization),
                    logRoots: roots
                ))
            }
            if !order.isEmpty {
                defaultClaudeCoworkRoots = defaultBucket
                AppLog.info(.config, "discovery: cowork partition — default keeps \(defaultBucket.count) sandbox dir(s), \(order.count) other account(s) found")
            }
        }

        let records = accountsStore.reconcile(with: observations)

        // The extra-card build plan: one card per distinct account found this launch, under its
        // reconciled record id.
        var claudeCards: [ClaudeAccountCard] = []
        for planned in plannedCards {
            guard let record = records.first(where: { $0.family == "claude" && $0.identityKey == planned.identityKey }) else {
                continue
            }
            guard record.id != "claude" else {
                // The bare record's account has moved out of the default home into a side login
                // while another account occupies the default. The bare CARD is the default home's
                // runtime, so this record can't render under its own id this launch. Proper swap
                // support re-points this in Phase 4; until then the parked account stays hidden.
                AppLog.warn(.config, "discovery: the claude record's account now lives outside the default home; its card is unavailable until swap support lands")
                continue
            }
            claudeCards.append(ClaudeAccountCard(
                id: record.id,
                displayName: record.derivedDisplayName,
                credential: planned.credential,
                logRoots: planned.logRoots
            ))
            identityKeys[record.id] = planned.identityKey
            let kind = if case .desktop = planned.credential { "desktop (cowork)" } else { "config dir" }
            AppLog.info(.config, "accounts: extra claude card \(record.id) — \(kind), \(planned.logRoots.count) log root(s)")
        }
        claudeCards.sort { $0.id < $1.id }

        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            claudeCards: claudeCards,
            defaultClaudeExtraLogRoots: defaultClaudeExtraLogRoots,
            defaultClaudeCoworkRoots: defaultClaudeCoworkRoots
        )
    }

    /// Whether two Claude identity keys (`uuid` or `uuid|org`) name the same login. An identity
    /// file sometimes omits the org half (older files, files written mid-login), so a bare-uuid
    /// key still names the same account as a `uuid|org` key with the same uuid — org presence
    /// must never split one login into two cards. Two keys with DIFFERENT orgs stay distinct:
    /// same user, separate usage pools.
    static func sameClaudeAccount(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let lhsParts = lhs.split(separator: "|", maxSplits: 1)
        let rhsParts = rhs.split(separator: "|", maxSplits: 1)
        guard lhsParts.first == rhsParts.first else { return false }
        return lhsParts.count == 1 || rhsParts.count == 1
    }

    /// One distinct account's card plan before reconciliation assigns its record id.
    private struct PlannedClaudeCard {
        var identityKey: String
        var credential: ClaudeAccountCard.Credential
        var logRoots: [URL]
    }
}
