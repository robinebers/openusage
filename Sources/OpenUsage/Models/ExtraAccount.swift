import Foundation

/// An additional provider account beyond the default one the CLI is logged into. Each becomes its
/// own provider instance, pointed at its own config dir (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
struct ExtraAccount: Codable, Identifiable, Hashable, Sendable {
    /// Base provider key this account belongs to: "claude" or "codex".
    var provider: String
    /// Short stable token that makes the instance id unique, e.g. "oxl5l1".
    var slot: String
    /// User-facing label shown in the dashboard group header, e.g. "Work".
    var label: String
    /// Absolute path to the account's CLI config dir (holds its credentials).
    var configDir: String

    var id: String { instanceID }

    /// The provider instance id used everywhere ids key off (registry, layout, API): "claude@oxl5l1".
    var instanceID: String { "\(provider)@\(slot)" }
}
