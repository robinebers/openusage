import Foundation

@MainActor
enum ProviderCatalog {
    /// One runtime per account, in the order the accounts were added. Runtimes in `existing` are reused
    /// for accounts that are still present, so an account change never resets the others.
    static func make(
        accounts: [Account],
        vault: any CredentialVault,
        http: any HTTPClient = URLSessionHTTPClient(),
        claudeSessions: ClaudeSessions = ClaudeSessions(),
        reusing existing: [AccountProviderRuntime] = []
    ) -> [AccountProviderRuntime] {
        let existingByID = Dictionary(existing.map { ($0.account.id, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.map { account in
            guard let runtime = existingByID[account.id] else {
                return AccountProviderRuntime(account: account, vault: vault, http: http, claudeSessions: claudeSessions)
            }
            runtime.update(account)
            return runtime
        }
    }
}
