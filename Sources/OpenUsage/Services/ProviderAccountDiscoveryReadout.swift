import Foundation

struct ProviderAccountDiscoveryReadout: Sendable {
    struct Claude: Sendable {
        let outcome: DefaultAccountObserver.Outcome
        let swapAccounts: [ClaudeSwapAccount]
        let desktopOrganizations: [ClaudeDesktopOrganization]
        let desktopAnchor: String?
    }

    struct Codex: Sendable {
        let homeDirectory: URL
        let swaps: [CodexSwapAccount]
        let managedHomes: Set<String>
        let homeLogins: [CodexHomeLogin]
        let canonicalHomesByPath: [String: String]
        let piScan: PiCodexLoginScan
        let keychainIdentity: CodexAccountIdentity?
        let configuredHomes: Set<String>
        let codexHome: String?
        /// Logins OpenUsage signed in itself (see `CodexManagedAccountStore`), whether or not their
        /// home currently holds a usable token.
        let managedLogins: [CodexManagedLogin]
        let buildsCards: Bool
        let outcome: DefaultAccountObserver.Outcome
    }

    let claude: Claude?
    let codex: Codex?
}

struct ClaudeDesktopOrganization: Sendable {
    let id: String
    let identityKey: String
    let label: String
}

extension ProviderAccountAssembly {
    static func discover(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String>,
        managedCodexLogins: [CodexManagedLogin],
        listCodexHomeDirectories: @escaping @Sendable (String) -> [String],
        desktop: ClaudeDesktopAuthStore?,
        listDesktopOrganizationDirectories: @escaping @Sendable (URL) -> [String]
    ) async -> ProviderAccountDiscoveryReadout {
        let hasEstablishedCodexAccounts = accountsStore.records.contains {
            $0.family == "codex" && $0.identityKey.contains("|")
        }
        async let claude = Task.detached(priority: .userInitiated) {
            Self.readClaude(
                observer: observer,
                enabled: families.contains("claude"),
                desktop: desktop,
                listDirectories: listDesktopOrganizationDirectories
            )
        }.value
        async let codex = Task.detached(priority: .userInitiated) {
            Self.readCodex(
                observer: observer,
                enabled: families.contains("codex"),
                hasEstablishedAccounts: hasEstablishedCodexAccounts,
                managedLogins: managedCodexLogins,
                listDirectories: listCodexHomeDirectories
            )
        }.value
        return await ProviderAccountDiscoveryReadout(claude: claude, codex: codex)
    }

    nonisolated static func readClaude(
        observer: DefaultAccountObserver,
        enabled: Bool,
        desktop: ClaudeDesktopAuthStore?,
        listDirectories: @Sendable (URL) -> [String]
    ) -> ProviderAccountDiscoveryReadout.Claude? {
        guard enabled else { return nil }
        let outcome = observer.observeClaude()
        let swapAccounts = ClaudeSwapAccount.discover(
            files: observer.files, home: observer.homeDirectory()
        )
        let defaultIdentity: String? = if case .resolved(let identityKey, _, _) = outcome {
            identityKey
        } else {
            nil
        }
        guard !(defaultIdentity.map { !$0.contains("|") } == true && swapAccounts.isEmpty) else {
            return ProviderAccountDiscoveryReadout.Claude(
                outcome: outcome, swapAccounts: swapAccounts, desktopOrganizations: [],
                desktopAnchor: nil
            )
        }

        let desktop = desktop ?? ClaudeDesktopAuthStore(
            files: observer.files, homeDirectory: observer.homeDirectory
        )
        let organizations = discoverDesktopOrganizations(
            desktop: desktop,
            cliIdentity: defaultIdentity,
            listDirectories: listDirectories
        )
        let anchor = desktop.homeDirectory()
            .appendingPathComponent("Library/Application Support/Claude").path
        return ProviderAccountDiscoveryReadout.Claude(
            outcome: outcome, swapAccounts: swapAccounts,
            desktopOrganizations: organizations, desktopAnchor: anchor
        )
    }

    nonisolated static func readCodex(
        observer: DefaultAccountObserver,
        enabled: Bool,
        hasEstablishedAccounts: Bool,
        managedLogins: [CodexManagedLogin],
        listDirectories: @escaping @Sendable (String) -> [String]
    ) -> ProviderAccountDiscoveryReadout.Codex? {
        guard enabled else { return nil }
        let homeDirectory = observer.homeDirectory()
        let swaps = CodexSwapAccount.discover(
            environment: observer.environment, files: observer.files, home: homeDirectory
        )
        let managedHomes = Set(CodexSwapAccount.managedHomes(
            environment: observer.environment, files: observer.files, home: homeDirectory
        ).map { CodexHomeScanner.canonicalHome($0, homeDirectory: homeDirectory) })
        // Homes OpenUsage signed in itself join the scan like any other independent home: a token
        // there names its account, rotates in place, and counts that home's own session logs.
        let homeLogins = CodexHomeScanner(
            environment: observer.environment,
            files: observer.files,
            homeDirectory: observer.homeDirectory,
            listDirectories: listDirectories
        ).scan(additionalHomes: swaps.map(\.mainHome) + managedLogins.map(\.home)).logins
        let canonicalHomesByPath: [String: String] = Dictionary(uniqueKeysWithValues: homeLogins.map {
            login -> (String, String) in
            (login.home, CodexHomeScanner.canonicalHome(login.home, homeDirectory: homeDirectory))
        })
        let piScan = PiCodexLoginScanner(
            environment: observer.environment, files: observer.files, homeDirectory: observer.homeDirectory
        ).scan()
        let auth = CodexAuthStore(
            environment: observer.environment, files: observer.files, keychain: observer.keychain
        )
        let keychainIdentity: CodexAccountIdentity? = {
            guard let state = auth.loadKeychainAuth(), state.hasUsableAccessToken else { return nil }
            return CodexAccountIdentity(auth: state.auth)
        }()
        let configuredHomes = Set(CodexHomeScanner.configuredHomes(
            environment: observer.environment, homeDirectory: homeDirectory
        ))
        let homeIdentities = homeLogins.map(\.identity)
        let piIdentities = piScan.logins.map(\.identity)
        let swapIdentities = swaps.map(\.identity)
        let keychainIdentities = [keychainIdentity].compactMap { $0 }
        // A managed login whose token is gone still names its account, so its card stays reachable
        // for Sign In Again instead of vanishing.
        let managedIdentities = managedLogins.compactMap(\.identity)
        let knownIdentities = Set(homeIdentities + piIdentities + swapIdentities + keychainIdentities + managedIdentities)
        // A login OpenUsage made itself is always an account card, even when it is the only login:
        // the plain card would run it unscoped (no identity stamp on its cache or synced history,
        // every home's spend counted as its own).
        let buildsCards = !swaps.isEmpty || hasEstablishedAccounts || knownIdentities.count > 1
            || !managedIdentities.isEmpty
        let outcome = observer.observeCodex()
        return ProviderAccountDiscoveryReadout.Codex(
            homeDirectory: homeDirectory, swaps: swaps, managedHomes: managedHomes,
            homeLogins: homeLogins, canonicalHomesByPath: canonicalHomesByPath,
            piScan: piScan, keychainIdentity: keychainIdentity,
            configuredHomes: configuredHomes, codexHome: auth.codexHome(),
            managedLogins: managedLogins, buildsCards: buildsCards, outcome: outcome
        )
    }

    nonisolated private static func discoverDesktopOrganizations(
        desktop: ClaudeDesktopAuthStore,
        cliIdentity: String?,
        listDirectories: @Sendable (URL) -> [String]
    ) -> [ClaudeDesktopOrganization] {
        guard let user = desktop.lastKnownAccountUUID(), desktop.hasCredentialMaterial() else { return [] }
        let active = desktop.load(allowInteraction: false, expectedAccountUUID: user)
        let activeOrganization = active.organization

        let root = desktop.homeDirectory().appendingPathComponent("Library/Application Support/Claude")
        let memberships = Set(["claude-code-sessions", "local-agent-mode-sessions"].flatMap { directory in
            listDirectories(root.appendingPathComponent(directory).appendingPathComponent(user))
                .compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        })
        var organizations = memberships
        if let activeOrganization { organizations.insert(activeOrganization) }
        if let text = try? desktop.files.readTextIfPresent(root.appendingPathComponent("config.json").path),
           let rootObject = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        {
            organizations.formUnion(rootObject.keys.compactMap {
                $0.split(separator: ":").last.flatMap { UUID(uuidString: String($0))?.uuidString.lowercased() }
            })
        }
        if let text = try? desktop.files.readTextIfPresent(
            root.appendingPathComponent("plan-usage-history.json").path
        ), let history = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let samples = history["samples"] as? [[String: Any]]
        {
            organizations.formUnion(samples.compactMap {
                ($0["org"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            })
        }
        let cliOrganization = cliIdentity.flatMap { identity -> String? in
            let parts = identity.split(separator: "|")
            guard parts.count == 2,
                  String(parts[0]).caseInsensitiveCompare(user) == .orderedSame
            else { return nil }
            return String(parts[1]).lowercased()
        }

        return organizations.sorted { lhs, rhs in
            lhs == activeOrganization ? true : rhs == activeOrganization ? false : lhs < rhs
        }.compactMap { organization in
            guard memberships.contains(organization)
                || organization == activeOrganization || organization == cliOrganization
            else { return nil }
            let result = organization == activeOrganization ? active : desktop.load(
                allowInteraction: false, organization: organization, expectedAccountUUID: user
            )
            guard result.status == .available || result.status == .permissionRequired else { return nil }
            let plan = result.oauth?.subscriptionType?.lowercased()
            let label = plan.map { ["max", "pro", "free"].contains($0) } == true ? "Personal"
                : plan?.capitalized ?? "Organization \(organization.prefix(8))"
            return ClaudeDesktopOrganization(id: organization, identityKey: "\(user)|\(organization)", label: label)
        }
    }
}
