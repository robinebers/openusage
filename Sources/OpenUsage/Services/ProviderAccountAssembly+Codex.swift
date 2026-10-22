import Foundation

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identity: CodexAccountIdentity
    let displayName: String
    let authHomes: [String]
    /// Canonical paths of the account's own Codex homes — never one xswap manages — whose tokens
    /// OpenUsage may refresh and write back.
    let writableAuthHomes: [String]
    let piCredentialSources: [CodexPiCredentialSource]
    /// pi's usage logs name no account, so they count for the account in pi's `openai-codex` login.
    let claimsPiUsage: Bool
    /// The account was signed in from OpenUsage (a managed home), so its login is renewed under
    /// Customize → Codex → Codex Accounts rather than in Codex, xswap, or pi.
    var hasManagedLogin = false
}

/// What the Codex account pass found: account cards once more than one account is known (or once a
/// login was added in OpenUsage, whose card is always scoped), otherwise the read-only logins the
/// plain `codex` card may fall back to when its only account lives in a sibling home or in pi.
struct CodexAccountDiscovery: Equatable, Sendable {
    var cards: [CodexAccountCard] = []
    /// Identity keys of every account signed in somewhere OpenUsage did not create (default home,
    /// sibling homes, xswap, pi, Keychain). Add Account refuses to re-add one of these: the browser
    /// picked the account the user already has, not a new one. `nil` when this launch ran no Codex
    /// discovery at all, so they are unknown rather than absent.
    var externalIdentityKeys: Set<String>? = nil
    /// The install runs in account-card mode (xswap, saved account records, more than one account, or
    /// a managed login). When it does and `cards` is still empty, no login with a known account is
    /// left (none at all, or only logins whose account this launch could not read): the plain
    /// fallback card then names no account and must not inherit anyone's synced history.
    var isAccountAware = false
    /// The homes the account cards divide between them; unused by the plain card.
    var historyHomes = CodexHistoryHomes(homes: [], defaultHome: "", registeredOwners: [:])
    var plainAuthHomes: [String] = []
    /// The independent homes among `plainAuthHomes`; see `CodexAccountCard.writableAuthHomes`.
    var plainWritableAuthHomes: [String] = []
    var plainPiCredentialSources: [CodexPiCredentialSource] = []
}

extension ProviderAccountAssembly {
    /// One card per ChatGPT account found across Codex homes, pi logins, Swap slots, and the Keychain.
    /// A lone account stays on the plain `codex` provider; cards appear once a second account is
    /// known, once Swap or the saved registry already made this a multi-account install, or once a
    /// login was added in OpenUsage (a managed login is always scoped to its own card).
    static func makeCodexCards(
        readout: ProviderAccountDiscoveryReadout.Codex,
        accountsStore: ProviderAccountsStore
    ) -> CodexAccountDiscovery {
        let homeDirectory = readout.homeDirectory
        let swaps = readout.swaps
        let managedHomes = readout.managedHomes
        let homeLogins = readout.homeLogins
        let canonicalHomesByPath = readout.canonicalHomesByPath
        let piScan = readout.piScan
        let keychainIdentity = readout.keychainIdentity
        let configuredHomes = readout.configuredHomes
        let managedHomePaths = Set(readout.managedLogins.map {
            CodexHomeScanner.standardizedHome($0.home, homeDirectory: homeDirectory)
        })
        let externalIdentityKeys = Set(
            homeLogins.filter { !managedHomePaths.contains($0.home) }.map(\.identity.key)
                + [keychainIdentity].compactMap { $0?.key }
                + swaps.map(\.identity.key)
                + piScan.logins.map(\.identity.key)
        )
        guard readout.buildsCards else {
            let plainHomes = homeLogins.map(\.home).filter { !configuredHomes.contains($0) }
            return CodexAccountDiscovery(
                externalIdentityKeys: externalIdentityKeys,
                isAccountAware: false,
                plainAuthHomes: plainHomes,
                plainWritableAuthHomes: Set(plainHomes.map {
                    canonicalHomesByPath[$0] ?? $0
                }).subtracting(managedHomes).sorted(),
                plainPiCredentialSources: piScan.logins.map {
                    CodexPiCredentialSource(path: $0.authPath, providerID: $0.providerID)
                }
            )
        }

        var observations: [ProviderAccountsStore.Observation] = []
        var identities: [CodexAccountIdentity] = []
        var labels: [String: String] = [:]
        var namedByTool = Set<String>()

        /// The email names the account; a workspace id only stands in when the login carries none.
        func label(for identity: CodexAccountIdentity, preferred: String? = nil) -> String {
            if let preferred = preferred?.nilIfEmpty { return "Codex: \(preferred)" }
            return "Codex: \(identity.email ?? identity.workspaceLabel)"
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
        // Logins the user made outside OpenUsage come first, managed homes last: the first account
        // observed in a family keeps the bare `codex` id, and an install whose only external login is
        // pi or the Keychain must keep that id (and its layout and stars) on the account it already
        // showed, not hand it to the account that was just added.
        let (managedHomeLogins, externalHomeLogins) = homeLogins.partitioned { managedHomePaths.contains($0.home) }
        for login in externalHomeLogins {
            let isConfigured = configuredHomes.contains(login.home)
            let holdsDefault = isConfigured && !assignedDefault
            if holdsDefault { assignedDefault = true }
            observe(login.identity, label: label(for: login.identity),
                    source: .init(kind: isConfigured ? .defaultHome : .codexHome, anchor: login.home,
                                  holdsDefaultSource: holdsDefault))
        }
        // The Keychain login comes before saved slots so it retains the default card on a first launch.
        if let keychainIdentity {
            observe(keychainIdentity, label: label(for: keychainIdentity),
                    source: .init(kind: .defaultHome, anchor: nil, holdsDefaultSource: !assignedDefault))
            assignedDefault = true
        }
        for swap in swaps {
            observe(swap.identity, label: swap.displayName, named: swap.alias != nil,
                    source: .init(kind: .codexSwap, anchor: swap.home, holdsDefaultSource: false))
        }
        for login in piScan.logins {
            observe(login.identity, label: label(for: login.identity, preferred: login.label ?? login.identity.email),
                    named: login.label != nil,
                    source: .init(kind: .pi, anchor: login.providerID, holdsDefaultSource: false))
        }
        for login in managedHomeLogins {
            observe(login.identity, label: label(for: login.identity),
                    source: .init(kind: .codexHome, anchor: login.home, holdsDefaultSource: false))
        }
        // A signed-in managed home was just observed; this keeps the card of a managed login whose
        // token is gone, so Sign In Again has a card to come back to.
        for login in readout.managedLogins {
            guard let identity = login.identity else { continue }
            observe(identity, label: label(for: identity),
                    source: .init(kind: .codexHome, anchor: login.home, holdsDefaultSource: false))
        }

        // One email in two workspaces is two accounts; cards that would read the same keep their
        // workspace in the name so the dashboard can tell them apart.
        let sharedLabels = Set(Dictionary(grouping: labels.keys, by: { labels[$0]! })
            .filter { $0.value.count > 1 }.keys)
        for identity in identities where sharedLabels.contains(labels[identity.key] ?? "") {
            labels[identity.key] = "\(labels[identity.key]!) (\(identity.workspaceLabel))"
        }

        let records = accountsStore.reconcile(with: observations)
        func standardized(_ home: String) -> String {
            CodexHomeScanner.standardizedHome(home, homeDirectory: homeDirectory)
        }
        let swapHomes = swaps.flatMap { [$0.mainHome, $0.home] }.map(standardized)
        let defaultHome = standardized(readout.codexHome ?? "~/.codex")
        // xswap's main home follows whoever is signed in there; only its separate account homes keep
        // the registered owner when their own auth.json is missing.
        var registeredOwners: [String: CodexAccountIdentity] = [:]
        for swap in swaps where standardized(swap.home) != standardized(swap.mainHome) {
            registeredOwners[standardized(swap.home)] = swap.identity
        }
        // A managed home whose login lapsed still holds that account's sessions: the verified
        // identity recorded at sign-in keeps owning them until a live login says otherwise.
        let ownedHomes = readout.managedLogins.compactMap { login -> String? in
            guard let identity = login.identity else { return nil }
            let home = standardized(login.home)
            if registeredOwners[home] == nil { registeredOwners[home] = identity }
            return home
        }
        let historyHomes = CodexHistoryHomes(
            homes: configuredHomes.union(homeLogins.map(\.home)).union(swapHomes).union(ownedHomes)
                .union([defaultHome]).sorted(),
            defaultHome: defaultHome, registeredOwners: registeredOwners
        )
        let piUsageOwner = piScan.logins.first { $0.providerID == PiCodexLoginScanner.providerPrefix }?.identity
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
            let writableHomes = Set(matchingHomes.map { canonicalHomesByPath[$0] ?? $0 })
                .subtracting(managedHomes)
            return CodexAccountCard(id: record.id, identity: identity,
                displayName: labels[identity.key] ?? "Codex",
                authHomes: Set(matchingHomes + matchingSwapHomes).sorted(),
                writableAuthHomes: writableHomes.sorted(),
                piCredentialSources: matchingPi, claimsPiUsage: piUsageOwner == identity,
                hasManagedLogin: readout.managedLogins.contains { $0.identityKey == identity.key })
        }
        return CodexAccountDiscovery(
            cards: cards, externalIdentityKeys: externalIdentityKeys, isAccountAware: true, historyHomes: historyHomes
        )
    }
}

private extension Array {
    /// `(matching, rest)`, each in the original order.
    func partitioned(by belongsToFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if belongsToFirst(element) { first.append(element) } else { second.append(element) }
        }
        return (first, second)
    }
}
