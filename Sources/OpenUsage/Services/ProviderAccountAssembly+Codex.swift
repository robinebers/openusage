import Foundation

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identityKey: String
    let displayName: String
    let authPaths: [String]
    let logHomes: [String]
    let piProviderIDs: [String]
    let piLogin: PiCodexLogin?
    let ownsUnattributedSources: Bool
}

extension ProviderAccountAssembly {
    static func assembleCodexCards(
        outcome: DefaultAccountObserver.Outcome?,
        discovery: CodexAccountDiscovery,
        observations: inout [ProviderAccountsStore.Observation],
        reconcile: ([ProviderAccountsStore.Observation]) -> [ProviderAccountRecord],
        identityKeys: inout [String: String]
    ) -> [CodexAccountCard] {
        if case .unresolved = outcome {
            reconcileOnly(observations, reconcile: reconcile)
            return []
        }
        var defaultIdentity: String?
        var defaultAnchor: String?
        if case .resolved(let identityKey, _, let anchor) = outcome {
            defaultIdentity = identityKey
            defaultAnchor = anchor
        }

        let homeLogins = discovery.homeLogins()
        let piLogins = discovery.piLogins()
        var identities: [String] = []
        func note(_ identity: String) {
            if !identities.contains(identity) { identities.append(identity) }
        }
        if let defaultIdentity { note(defaultIdentity) }
        homeLogins.forEach { note($0.accountID) }
        piLogins.forEach { note($0.accountID) }
        guard !identities.isEmpty else {
            reconcileOnly(observations, reconcile: reconcile)
            return []
        }

        for identity in identities {
            let homes = homeLogins.filter { $0.accountID == identity }
            let pis = piLogins.filter { $0.accountID == identity }
            var sources: [ProviderAccountSource] = []
            for login in homes where login.home != defaultAnchor {
                sources.append(ProviderAccountSource(kind: .codexHome, anchor: login.home, holdsDefaultSource: false))
            }
            for login in pis {
                sources.append(ProviderAccountSource(kind: .piAuth, anchor: login.providerID, holdsDefaultSource: false))
            }
            let label = pis.compactMap(\.label).first
                ?? homes.compactMap(\.email).first
                ?? pis.compactMap(\.email).first
            if let index = observations.firstIndex(where: { $0.family == "codex" && $0.identityKey == identity }) {
                observations[index].sources += sources
                if let label { observations[index].label = label }
            } else {
                observations.append(ProviderAccountsStore.Observation(
                    family: "codex", identityKey: identity, label: label, sources: sources
                ))
            }
        }
        if identities.count > 1 {
            AppLog.info(.config, "accounts: discovered \(identities.count) Codex accounts across \(homeLogins.count) homes and \(piLogins.count) pi logins")
        }

        let records = reconcile(observations)
        var cards: [CodexAccountCard] = []
        let unattributedOwner = defaultIdentity ?? identities.first
        for identity in identities {
            guard let record = records.first(where: {
                $0.family == "codex" && $0.identityKey == identity && !$0.removedTombstone
            }) else { continue }
            let matchingHomes = homeLogins.filter { $0.accountID == identity }
            let homes = matchingHomes.filter { $0.home == defaultAnchor } + matchingHomes.filter { $0.home != defaultAnchor }
            let pis = piLogins.filter { $0.accountID == identity }
            let label = record.label ?? "Account \(identity.prefix(8))"
            cards.append(CodexAccountCard(
                id: record.id,
                identityKey: identity,
                displayName: identities.count == 1 ? "Codex" : "Codex: \(label)",
                authPaths: homes.map(\.authPath),
                logHomes: homes.map(\.home),
                piProviderIDs: pis.map(\.providerID),
                piLogin: pis.first,
                ownsUnattributedSources: identity == unattributedOwner
            ))
            identityKeys[record.id] = identity
        }
        if let defaultIdentity, let card = cards.first(where: { $0.identityKey == defaultIdentity }), card.id != "codex" {
            identityKeys.removeValue(forKey: "codex")
        }
        return cards
    }

    private static func reconcileOnly(
        _ observations: [ProviderAccountsStore.Observation],
        reconcile: ([ProviderAccountsStore.Observation]) -> [ProviderAccountRecord]
    ) {
        _ = reconcile(observations)
    }
}
