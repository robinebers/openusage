import Foundation

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identity: CodexAccountIdentity
    let displayName: String
    let authHomes: [String]
    let piCredentialSources: [CodexPiCredentialSource]
    let logHomes: [String]
    let allowsUnattributedHistory: Bool
}

extension ProviderAccountAssembly {
    /// One card per ChatGPT account found across Codex homes, pi logins, Swap slots, and the Keychain.
    /// A lone account stays on the plain `codex` provider; cards appear once a second account is
    /// known, or once Swap or the saved registry already made this a multi-account install.
    static func makeCodexCards(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        listDirectories: @escaping @Sendable (String) -> [String] = CodexHomeScanner.listSubdirectories
    ) async -> (cards: [CodexAccountCard], allowsUnattributedHistory: Bool) {
        let homeDirectory = observer.homeDirectory()
        let swaps = CodexSwapAccount.discover(
            environment: observer.environment, files: observer.files, home: homeDirectory
        )
        let homeLogins = CodexHomeScanner(
            environment: observer.environment,
            files: observer.files,
            homeDirectory: observer.homeDirectory,
            listDirectories: listDirectories
        ).logins(additionalHomes: swaps.map(\.mainHome))
        let piScan = PiCodexLoginScanner(
            environment: observer.environment, files: observer.files, homeDirectory: observer.homeDirectory
        ).scan()
        let hasEstablishedAccounts = accountsStore.records.contains {
            $0.family == "codex" && $0.identityKey.contains("|")
        }
        let knownIdentities = Set(
            homeLogins.map(\.identity) + piScan.logins.map(\.identity) + swaps.map(\.identity)
        )
        // History with no provable owner counts only while exactly one account exists and no login
        // is too incomplete to rule out a second one.
        let hasIncompleteLogin = piScan.hasIncompleteLogin
            || homeLogins.contains { !CodexAccountIdentity.isComplete(key: $0.identity.key) }
        guard !swaps.isEmpty || hasEstablishedAccounts || knownIdentities.count > 1 else {
            return ([], knownIdentities.isEmpty || !piScan.hasIncompleteLogin)
        }

        let configuredHomes = Set(CodexHomeScanner.configuredHomes(
            environment: observer.environment, homeDirectory: homeDirectory
        ))
        var observations: [ProviderAccountsStore.Observation] = []
        var identities: [CodexAccountIdentity] = []
        var labels: [String: String] = [:]
        var namedByTool = Set<String>()

        func label(for identity: CodexAccountIdentity, preferred: String? = nil) -> String {
            if let preferred = preferred?.nilIfEmpty { return "Codex: \(preferred)" }
            let workspace = identity.accountID.isEmpty ? "Unknown" : String(identity.accountID.prefix(8))
            return "Codex: Workspace \(workspace) (\(identity.email ?? identity.accountID))"
        }

        /// A name the user chose in xswap or pi beats the generic workspace label; the first such name wins.
        func observe(_ identity: CodexAccountIdentity, label: String, named: Bool = false,
                     source: ProviderAccountSource) {
            accountsStore.upgradeCodexIdentity(identity)
            if let index = observations.firstIndex(where: { $0.identityKey == identity.key }) {
                if !observations[index].sources.contains(source) { observations[index].sources.append(source) }
            } else {
                identities.append(identity)
                observations.append(.init(family: "codex", identityKey: identity.key,
                                          label: identity.email, sources: [source]))
            }
            if named ? namedByTool.insert(identity.key).inserted : labels[identity.key] == nil {
                labels[identity.key] = label
            }
        }

        var assignedDefault = false
        for login in homeLogins {
            let isConfigured = configuredHomes.contains(login.home)
            let holdsDefault = isConfigured && !assignedDefault
            if holdsDefault { assignedDefault = true }
            observe(login.identity, label: label(for: login.identity),
                    source: .init(kind: isConfigured ? .defaultHome : .codexHome, anchor: login.home,
                                  holdsDefaultSource: holdsDefault))
        }
        // Keychain can hold a different default login with no auth.json or saved Swap slot.
        // Discover it before saved slots so it retains the default card on a first launch.
        let auth = CodexAuthStore(environment: observer.environment, files: observer.files,
                                  keychain: observer.keychain)
        if let state = await loadOffMainActor({ auth.loadKeychainAuth() }), state.hasUsableAccessToken,
           let identity = CodexAccountIdentity(auth: state.auth) {
            observe(identity, label: label(for: identity),
                    source: .init(kind: .defaultHome, anchor: nil, holdsDefaultSource: !assignedDefault))
            assignedDefault = true
        }
        for swap in swaps {
            observe(swap.identity, label: swap.displayName, named: true,
                    source: .init(kind: .codexSwap, anchor: swap.home, holdsDefaultSource: false))
        }
        for login in piScan.logins {
            observe(login.identity, label: label(for: login.identity, preferred: login.label ?? login.identity.email),
                    named: login.label != nil,
                    source: .init(kind: .pi, anchor: login.providerID, holdsDefaultSource: false))
        }

        let records = accountsStore.reconcile(with: observations)
        let allowsUnattributed = !hasIncompleteLogin && records.count { $0.family == "codex" } == 1
        let swapHomes = swaps.flatMap { [$0.mainHome, $0.home] }
            .map { CodexHomeScanner.standardizedHome($0, homeDirectory: homeDirectory) }
        let logHomes = Set(homeLogins.map(\.home)).union(swapHomes).sorted()
        // Registry order is persistent; observation order follows the current default login.
        // Even an uncustomized layout must keep its cards in place after a switch and relaunch.
        let cards = records.compactMap { record -> CodexAccountCard? in
            guard record.family == "codex", !record.removedTombstone,
                  let identity = identities.first(where: { $0.key == record.identityKey })
            else { return nil }
            let matchingHomes = homeLogins.filter { $0.identity == identity }.map(\.home)
            let matchingSwapHomes = swaps.filter { $0.identity == identity }.flatMap { [$0.mainHome, $0.home] }
            let matchingPi = piScan.logins.filter { $0.identity == identity }.map {
                CodexPiCredentialSource(path: $0.authPath, providerID: $0.providerID)
            }
            return CodexAccountCard(id: record.id, identity: identity,
                displayName: labels[identity.key] ?? "Codex",
                authHomes: Set(matchingHomes + matchingSwapHomes).sorted(),
                piCredentialSources: matchingPi,
                logHomes: logHomes, allowsUnattributedHistory: allowsUnattributed)
        }
        return (cards, allowsUnattributed)
    }
}
