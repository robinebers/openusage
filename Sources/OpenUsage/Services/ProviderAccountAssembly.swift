import Foundation

struct ClaudeAccountCard: Equatable, Sendable {
    let id: String
    let identityKey: String
    let organizationID: String?
    let displayName: String
    let usesDesktopCredentials: Bool
    let allowsUnattributedPiUsage: Bool
    var swapAccount: ClaudeSwapAccount? = nil
    var additionalLogDirectories: [String] = []
    var organizationName: String? = nil
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// reconcile the account registry, and expose the per-card identity map that the snapshot cache's
/// account stamp consumes. Runs once per launch (app) or per invocation (one-shot CLI); a mid-run
/// swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. Phase 1 observes only default
    /// homes, so the keys are the bare family ids; a family whose identity didn't resolve is absent.
    let identityKeysByCard: [String: String]
    var claudeCards: [ClaudeAccountCard] = []
    var codex = CodexAccountDiscovery()
    /// The families this pass actually read. A family left out (not requested, or its home facts
    /// unreadable this launch) has no cards here, which must not be mistaken for "no accounts".
    var readFamilies: Set<String> = []
    var codexCards: [CodexAccountCard] { codex.cards }

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports). `families` narrows the
    /// pass: the live reload after a Codex account change reads only Codex.
    static func make(
        defaults: UserDefaults = .standard, waitsForLoginShell: Bool,
        managedCodexRoot: URL = CodexManagedAccountStore.managedRoot(),
        families requested: Set<String> = ProviderAccountID.families
    ) async -> ProviderAccountAssembly {
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
            ? requested
            : requested.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < requested.count {
            AppLog.info(.config, "account identity read skipped for \(requested.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        let assemblyStartedAt = ProcessInfo.processInfo.systemUptime
        let assembly = await make(
            observer: DefaultAccountObserver(
                environment: ProcessEnvironmentReader(blocksOnShellCapture: false)
            ),
            accountsStore: ProviderAccountsStore(defaults: defaults),
            families: families,
            managedCodexLogins: CodexManagedAccountStore(defaults: defaults, root: managedCodexRoot).logins
        )
        let assemblyDurationMS = Int((ProcessInfo.processInfo.systemUptime - assemblyStartedAt) * 1_000)
        AppLog.info(.config, "account assembly duration: \(assemblyDurationMS) ms")
        return assembly
    }

    /// The environment variable that relocates each family's default home — the fact whose
    /// invisibility (shell layers unreadable AND not in the process environment) makes that family's
    /// identity read unsafe on a first launch.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// The environment-independent core, separated so tests inject a fixed observer and scratch
    /// store. `families` limits the pass to the families whose home facts are readable this launch
    /// (see `make(defaults:waitsForLoginShell:)`); a family left out is simply not observed —
    /// no identity key, no reconciliation, exactly as if the pass never ran for it.
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        managedCodexLogins: [CodexManagedLogin] = [],
        listCodexHomeDirectories: @escaping @Sendable (String) -> [String] = CodexHomeScanner.listSubdirectories,
        desktop: ClaudeDesktopAuthStore? = nil,
        listDesktopOrganizationDirectories: @escaping @Sendable (URL) -> [String] = { root in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { return nil }
                return url.lastPathComponent
            }
        }
    ) async -> ProviderAccountAssembly {
        let readout = await discover(
            observer: observer,
            accountsStore: accountsStore,
            families: families,
            managedCodexLogins: managedCodexLogins,
            listCodexHomeDirectories: listCodexHomeDirectories,
            desktop: desktop,
            listDesktopOrganizationDirectories: listDesktopOrganizationDirectories
        )
        return assemble(readout: readout, accountsStore: accountsStore)
    }

    @MainActor
    static func assemble(
        readout: ProviderAccountDiscoveryReadout,
        accountsStore: ProviderAccountsStore
    ) -> ProviderAccountAssembly {
        let codex = readout.codex.map {
            makeCodexCards(readout: $0, accountsStore: accountsStore)
        } ?? CodexAccountDiscovery()
        let readFamilies = Set([readout.claude == nil ? nil : "claude", readout.codex == nil ? nil : "codex"].compactMap { $0 })
        let codexCards = codex.cards
        var identityKeys = Dictionary(uniqueKeysWithValues: codexCards.map { ($0.id, $0.identity.key) })
        var observations: [ProviderAccountsStore.Observation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", readout.claude?.outcome),
            ("codex", codexCards.isEmpty ? readout.codex?.outcome : nil),
        ].compactMap { family, outcome in
            outcome.map { (family, $0) }
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.Observation(
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

        guard let claudeReadout = readout.claude else {
            accountsStore.reconcile(with: observations)
            return ProviderAccountAssembly(identityKeysByCard: identityKeys, codex: codex, readFamilies: readFamilies)
        }

        let swapAccounts = claudeReadout.swapAccounts
        if !swapAccounts.isEmpty {
            AppLog.info(.config, "accounts: discovered \(swapAccounts.count) Claude Swap accounts")
        }
        for account in swapAccounts {
            let source = ProviderAccountSource(kind: .claudeSwap, anchor: account.sessionDirectory, holdsDefaultSource: false)
            if let index = observations.firstIndex(where: {
                $0.family == "claude" && $0.identityKey == account.identityKey
            }) {
                observations[index].sources.append(source)
            } else {
                observations.append(ProviderAccountsStore.Observation(
                    family: "claude", identityKey: account.identityKey, label: "\(account.email) (\(account.organizationName ?? "Organization \(account.organizationID.prefix(8))"))", sources: [source]
                ))
            }
        }

        if let claudeIdentity = identityKeys["claude"], !claudeIdentity.contains("|"), swapAccounts.isEmpty {
            accountsStore.reconcile(with: observations)
            return ProviderAccountAssembly(identityKeysByCard: identityKeys, codex: codex, readFamilies: readFamilies)
        }

        let desktopOrganizations = claudeReadout.desktopOrganizations
        let desktopAnchor = claudeReadout.desktopAnchor ?? ""
        for organization in desktopOrganizations {
            let source = ProviderAccountSource(
                kind: .defaultHome, anchor: desktopAnchor, holdsDefaultSource: false
            )
            if let index = observations.firstIndex(where: {
                $0.family == "claude" && $0.identityKey == organization.identityKey
            }) {
                observations[index].sources.append(source)
            } else {
                observations.append(ProviderAccountsStore.Observation(
                    family: "claude", identityKey: organization.identityKey,
                    label: organization.label, sources: [source]
                ))
            }
        }

        let defaultClaudeIdentity = identityKeys["claude"]
        let records = accountsStore.reconcile(with: observations)
        let allowsUnattributedPiUsage = records.count { $0.family == "claude" } == 1
        var cards: [ClaudeAccountCard] = []
        if let defaultIdentity = defaultClaudeIdentity,
           let organization = defaultIdentity.split(separator: "|").last,
           defaultIdentity.contains("|"),
           let record = records.first(where: {
               $0.family == "claude" && $0.identityKey == defaultIdentity && !$0.removedTombstone
           })
        {
            let label = outcomes.first(where: { $0.family == "claude" }).flatMap { outcome -> String? in
                guard case .resolved(_, let value, _) = outcome.outcome else { return nil }
                return organizationLabel(value)
            } ?? "Organization"
            cards.append(ClaudeAccountCard(
                id: record.id, identityKey: defaultIdentity, organizationID: String(organization),
                displayName: "Claude — \(label)", usesDesktopCredentials: false,
                allowsUnattributedPiUsage: allowsUnattributedPiUsage, organizationName: label
            ))
            identityKeys.removeValue(forKey: "claude")
            identityKeys[record.id] = defaultIdentity
        } else if let defaultIdentity = defaultClaudeIdentity,
                  let record = records.first(where: {
                      $0.family == "claude" && $0.identityKey == defaultIdentity && !$0.removedTombstone
                  }) {
            // A UUID without an organization remains a default login, separate from scoped cards.
            cards.append(ClaudeAccountCard(
                id: record.id, identityKey: defaultIdentity, organizationID: nil,
                displayName: "Claude: \(record.label ?? "Default Login")", usesDesktopCredentials: false,
                allowsUnattributedPiUsage: allowsUnattributedPiUsage
            ))
            identityKeys.removeValue(forKey: "claude")
            identityKeys[record.id] = defaultIdentity
        }
        for organization in desktopOrganizations where organization.identityKey != defaultClaudeIdentity {
            guard let record = records.first(where: {
                $0.family == "claude" && $0.identityKey == organization.identityKey && !$0.removedTombstone
            }) else { continue }
            let cardID = record.id
            guard !cards.contains(where: { $0.id == cardID }) else { continue }
            cards.append(ClaudeAccountCard(
                id: cardID, identityKey: organization.identityKey, organizationID: organization.id,
                displayName: "Claude — \(organizationLabel(record.label) ?? organization.label)",
                usesDesktopCredentials: true, allowsUnattributedPiUsage: allowsUnattributedPiUsage,
                organizationName: organizationLabel(record.label) ?? organization.label
            ))
            identityKeys[cardID] = organization.identityKey
        }

        for account in swapAccounts {
            if let index = cards.firstIndex(where: { $0.identityKey == account.identityKey }) {
                let existing = cards[index]
                cards[index] = ClaudeAccountCard(
                    id: existing.id, identityKey: existing.identityKey, organizationID: existing.organizationID,
                    displayName: account.displayName(fallbackOrganization: existing.organizationName),
                    usesDesktopCredentials: existing.usesDesktopCredentials,
                    allowsUnattributedPiUsage: allowsUnattributedPiUsage,
                    swapAccount: account, organizationName: account.organizationName ?? existing.organizationName
                )
                continue
            }
            guard let record = records.first(where: {
                $0.family == "claude" && $0.identityKey == account.identityKey && !$0.removedTombstone
            }) else { continue }
            cards.append(ClaudeAccountCard(
                id: record.id, identityKey: account.identityKey, organizationID: account.organizationID,
                displayName: account.displayName(), usesDesktopCredentials: false,
                allowsUnattributedPiUsage: allowsUnattributedPiUsage, swapAccount: account,
                organizationName: account.organizationName
            ))
            identityKeys[record.id] = account.identityKey
        }
        for index in cards.indices {
            cards[index].additionalLogDirectories = swapAccounts.map(\.sessionDirectory)
        }
        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys, claudeCards: cards, codex: codex, readFamilies: readFamilies
        )
    }

    private static func organizationLabel(_ value: String?) -> String? {
        guard let value, let opening = value.lastIndex(of: "("), value.last == ")" else { return value }
        return String(value[value.index(after: opening)..<value.index(before: value.endIndex)])
    }
}
