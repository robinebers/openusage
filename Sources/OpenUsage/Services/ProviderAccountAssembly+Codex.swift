import Foundation

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identity: CodexAccountIdentity
    let displayName: String
    let authHomes: [String]
    let writableAuthHomes: [String]
    let piCredentialSources: [CodexPiCredentialSource]
    let logHomes: [String]
    let allowsUnattributedHistory: Bool
}

extension ProviderAccountAssembly {
    static func makeCodexCards(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        discovery: CodexAccountDiscovery? = nil
    ) async -> [CodexAccountCard] {
        let discovery = discovery ?? CodexAccountDiscovery(
            environment: observer.environment,
            files: observer.files,
            homeDirectory: observer.homeDirectory
        )
        let swaps = CodexSwapAccount.discover(
            environment: observer.environment,
            files: observer.files,
            home: observer.homeDirectory()
        )
        let hasEstablishedAccounts = !swaps.isEmpty || accountsStore.records.contains(where: {
            $0.family == "codex" && $0.identityKey.contains("|")
        })
        let homes = discovery.homeLogins(additionalHomes: swaps.map(\.mainHome)).filter {
            hasEstablishedAccounts || CodexAccountIdentity.isComplete(key: $0.identity.key)
        }
        let piLogins = discovery.piLogins()
        guard hasEstablishedAccounts || !homes.isEmpty || !piLogins.isEmpty else { return [] }

        let configuredHomes = Set(CodexAccountDiscovery.configuredHomes(
            environment: observer.environment,
            homeDirectory: observer.homeDirectory()
        ))
        var observations: [ProviderAccountsStore.Observation] = []
        var identities: [CodexAccountIdentity] = []
        var labels: [String: String] = [:]

        func label(for identity: CodexAccountIdentity, preferred: String? = nil) -> String {
            if let preferred = preferred?.nilIfEmpty { return "Codex: \(preferred)" }
            let workspace = identity.accountID.isEmpty ? "Unknown" : String(identity.accountID.prefix(8))
            return "Codex: Workspace \(workspace) (\(identity.email ?? identity.accountID))"
        }

        func observe(_ identity: CodexAccountIdentity, label: String, source: ProviderAccountSource) {
            accountsStore.upgradeCodexIdentity(identity)
            if let index = observations.firstIndex(where: { $0.identityKey == identity.key }) {
                if !observations[index].sources.contains(source) { observations[index].sources.append(source) }
            } else {
                identities.append(identity)
                observations.append(.init(
                    family: "codex",
                    identityKey: identity.key,
                    label: identity.email,
                    sources: [source]
                ))
            }
            labels[identity.key] = label
        }

        var assignedDefault = false
        for login in homes {
            let isConfigured = configuredHomes.contains(login.home)
            let holdsDefault = isConfigured && !assignedDefault
            if holdsDefault { assignedDefault = true }
            observe(
                login.identity,
                label: label(for: login.identity),
                source: .init(
                    kind: isConfigured ? .defaultHome : .codexHome,
                    anchor: login.home,
                    holdsDefaultSource: holdsDefault
                )
            )
        }

        let auth = CodexAuthStore(
            environment: observer.environment,
            files: observer.files,
            keychain: observer.keychain
        )
        if let state = await loadOffMainActor({ auth.loadKeychainAuth() }),
           state.hasUsableAccessToken,
           let identity = CodexAccountIdentity(auth: state.auth) {
            observe(
                identity,
                label: label(for: identity),
                source: .init(kind: .defaultHome, anchor: nil, holdsDefaultSource: !assignedDefault)
            )
            assignedDefault = true
        }

        for swap in swaps {
            observe(
                swap.identity,
                label: swap.displayName,
                source: .init(kind: .codexSwap, anchor: swap.home, holdsDefaultSource: false)
            )
        }

        for login in piLogins {
            observe(
                login.identity,
                label: label(for: login.identity, preferred: login.label ?? login.identity.email),
                source: .init(kind: .pi, anchor: login.providerID, holdsDefaultSource: false)
            )
        }

        let records = accountsStore.reconcile(with: observations)
        let allowsUnattributed = records.count { $0.family == "codex" } == 1
        let allLogHomes = Array(Set(homes.map(\.home) + swaps.flatMap { [$0.mainHome, $0.home] })).sorted()

        return records.compactMap { record in
            guard record.family == "codex",
                  !record.removedTombstone,
                  let identity = identities.first(where: { $0.key == record.identityKey })
            else { return nil }
            let matchingHomes = homes.filter { $0.identity == identity }.map(\.home)
            let matchingSwaps = swaps.filter { $0.identity == identity }
            let matchingPi = piLogins.filter { $0.identity == identity }.map {
                CodexPiCredentialSource(path: $0.authPath, providerID: $0.providerID)
            }
            let authHomes = Array(Set(
                matchingHomes + matchingSwaps.flatMap { [$0.mainHome, $0.home] }
            )).sorted()
            return CodexAccountCard(
                id: record.id,
                identity: identity,
                displayName: records.count(where: { $0.family == "codex" && !$0.removedTombstone }) == 1
                    ? "Codex"
                    : labels[identity.key] ?? "Codex",
                authHomes: authHomes,
                writableAuthHomes: matchingHomes.filter { home in
                    !matchingSwaps.contains(where: { $0.home == home })
                },
                piCredentialSources: matchingPi,
                logHomes: allLogHomes,
                allowsUnattributedHistory: allowsUnattributed
            )
        }
    }
}
