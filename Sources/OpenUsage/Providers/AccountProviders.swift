import Foundation

/// Builds the extra provider instances for the user's additional accounts. Each instance reuses the
/// normal provider pipeline, only pointed at the account's own config dir via `OverrideEnvironment`
/// (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`). Unknown providers are skipped (only Claude and Codex support
/// the config-dir redirect).
///
/// De-duplication of accounts that resolve to the same email happens at the display layer (a provider
/// whose account email already appeared is hidden), using each provider's resolved identity (Claude's
/// profile API, Codex's `id_token`) — not here, where only the saved config is known.
enum AccountProviders {
    @MainActor
    static func extraProviders(for accounts: [ExtraAccount]) -> [ProviderRuntime] {
        accounts.compactMap { account in
            switch account.provider {
            case "claude":
                return ClaudeProvider(
                    instanceID: account.instanceID,
                    displayName: "Claude · \(account.label)",
                    authStore: ClaudeAuthStore(
                        environment: OverrideEnvironment(["CLAUDE_CONFIG_DIR": account.configDir])
                    )
                )
            case "codex":
                return CodexProvider(
                    instanceID: account.instanceID,
                    displayName: "Codex · \(account.label)",
                    authStore: CodexAuthStore(
                        environment: OverrideEnvironment(["CODEX_HOME": account.configDir])
                    )
                )
            default:
                return nil
            }
        }
    }
}
