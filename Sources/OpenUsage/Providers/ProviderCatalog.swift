import Foundation

@MainActor
enum ProviderCatalog {
    /// One runtime per account, reusing each account's runtime when it still fits. An account mirrored
    /// from a hub gets a runtime whose HTTP client tunnels through that hub, rebuilt when its link changes.
    static func make(
        accounts: [Account],
        vault: any CredentialVault,
        http: any HTTPClient = URLSessionHTTPClient(),
        hubGate: CLIProxyHubGate = CLIProxyHubGate(),
        claudeSessions: ClaudeSessions = ClaudeSessions(),
        reusing existing: [AccountProviderRuntime] = []
    ) -> [AccountProviderRuntime] {
        let existingByID = Dictionary(existing.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.map { account in
            guard let runtime = existingByID[account.id], runtime.account.hub == account.hub else {
                let client: any HTTPClient = account.hub.map {
                    HubTunnel(link: $0, kind: account.kind, vault: vault, client: CLIProxyHubClient(http: http, gate: hubGate))
                } ?? http
                return AccountProviderRuntime(account: account, vault: vault, http: client, claudeSessions: claudeSessions)
            }
            runtime.update(account)
            return runtime
        }
    }
}
