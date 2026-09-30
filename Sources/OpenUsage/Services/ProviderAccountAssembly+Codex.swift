import Foundation

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identity: CodexAccountIdentity
    let displayName: String
    let authHomes: [String]
    let logHomes: [String]
    let allowsUnattributedHistory: Bool
}

extension ProviderAccountAssembly {
    static func makeCodexCards(
        observer: DefaultAccountObserver, accountsStore: ProviderAccountsStore
    ) async -> [CodexAccountCard] {
        let swaps = CodexSwapAccount.discover(
            environment: observer.environment, files: observer.files, home: observer.homeDirectory()
        )
        guard !swaps.isEmpty || accountsStore.records.contains(where: {
            $0.family == "codex" && $0.identityKey.contains("|")
        }) else { return [] }
        let home = observer.homeDirectory().path
        func expanded(_ path: String) -> String {
            path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
        }
        let auth = CodexAuthStore(environment: observer.environment, files: observer.files,
                                  keychain: observer.keychain)
        let defaultPaths = auth.authPaths().map(expanded)
        let mainPaths = swaps.map { $0.mainHome + "/auth.json" }
        var observations: [ProviderAccountsStore.Observation] = []
        var identities: [CodexAccountIdentity] = []
        var labels: [String: String] = [:]
        func observe(_ identity: CodexAccountIdentity, label: String, source: ProviderAccountSource) {
            accountsStore.upgradeCodexIdentity(identity)
            if let index = observations.firstIndex(where: { $0.identityKey == identity.key }) {
                if !observations[index].sources.contains(source) { observations[index].sources.append(source) }
            } else {
                identities.append(identity)
                observations.append(.init(family: "codex", identityKey: identity.key,
                                          label: identity.email, sources: [source]))
            }
            labels[identity.key] = label
        }
        var seenPaths = Set<String>()
        for path in defaultPaths + mainPaths where seenPaths.insert(path).inserted {
            guard let state = auth.loadAuth(at: path), state.hasUsableAccessToken,
                  let identity = CodexAccountIdentity(auth: state.auth) else { continue }
            observe(identity, label: identity.displayName(),
                    source: .init(kind: .defaultHome, anchor: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                  holdsDefaultSource: observations.isEmpty))
        }
        // Keychain can hold a different default login with no auth.json or saved Swap slot.
        // Discover it before saved slots so it retains the default card on a first launch.
        if let state = await loadOffMainActor({ auth.loadKeychainAuth() }), state.hasUsableAccessToken,
           let identity = CodexAccountIdentity(auth: state.auth) {
            observe(identity, label: identity.displayName(),
                    source: .init(kind: .defaultHome, anchor: nil, holdsDefaultSource: observations.isEmpty))
        }
        for swap in swaps {
            observe(swap.identity, label: swap.displayName,
                    source: .init(kind: .codexSwap, anchor: swap.home, holdsDefaultSource: false))
        }
        let records = accountsStore.reconcile(with: observations)
        let allowsUnattributed = records.count { $0.family == "codex" } == 1
        let logHomes = Array(Set(swaps.flatMap { [$0.mainHome, $0.home] })).sorted()
        // Registry order is persistent; observation order follows the current default login.
        // Even an uncustomized layout must keep its cards in place after a switch and relaunch.
        let shown = records.compactMap { record -> (id: String, identity: CodexAccountIdentity)? in
            guard record.family == "codex", !record.removedTombstone,
                  let identity = identities.first(where: { $0.key == record.identityKey })
            else { return nil }
            return (record.id, identity)
        }
        // Cards are named by address alone. When one address is signed into several workspaces those
        // names would collide, so only those cards get their workspace back; an alias wins either way.
        var addressCount: [String: Int] = [:]
        for (_, identity) in shown {
            if let email = identity.email { addressCount[email, default: 0] += 1 }
        }
        return shown.map { id, identity in
            let matching = swaps.filter { $0.identity == identity }
            let observedHomes = observations.first { $0.identityKey == identity.key }?.sources.compactMap(\.anchor) ?? []
            var label = labels[identity.key] ?? "Codex"
            if label == identity.displayName(), let email = identity.email, addressCount[email, default: 0] > 1 {
                label = identity.displayName(disambiguatingWorkspace: true)
            }
            return CodexAccountCard(id: id, identity: identity,
                displayName: label,
                authHomes: Array(Set(observedHomes + matching.flatMap { [$0.mainHome, $0.home] })).sorted(),
                logHomes: logHomes, allowsUnattributedHistory: allowsUnattributed)
        }
    }
}
