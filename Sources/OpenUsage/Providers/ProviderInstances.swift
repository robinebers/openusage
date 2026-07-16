import CryptoKit
import Foundation

/// Identity helpers for provider-instance ids (`claude@ab12cd34`). The default login keeps the bare
/// provider id, so every existing install migrates by doing nothing; extra accounts get the base id
/// plus an `@`-suffixed hash of the *account identity* — keyed on who the account is, not where its
/// home lives, so a re-discovered account converges on the same instance id (and the same layout).
enum ProviderInstanceID {
    static func isInstance(_ providerID: String) -> Bool {
        providerID.contains("@")
    }

    /// The base provider id (`claude` for `claude@ab12cd34`; unchanged for non-instance ids).
    static func base(of providerID: String) -> String {
        guard let at = providerID.firstIndex(of: "@") else { return providerID }
        return String(providerID[..<at])
    }

    static func make(baseProviderID: String, identityKey: String) -> String {
        "\(baseProviderID)@\(hash8(identityKey))"
    }

    /// First 8 hex of SHA-256 — enough to never collide across a machine's handful of accounts while
    /// keeping metric ids (`claude@ab12cd34.session`) readable in logs and the local API.
    static func hash8(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.precomposedStringWithCanonicalMapping.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    /// Home-relative form for log lines: `~/.claude-work` instead of the absolute path. Keeps the
    /// username out AND survives the file log's absolute-path redaction, so a support log still says
    /// WHICH dir a note is about.
    static func logPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "-" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// One discovered extra login, persisted so ordinals ("Claude 2") and instance ids stay stable across
/// launches. Records are never removed in Phase 1 — a vanished home just surfaces the provider's normal
/// not-logged-in error on its card (the user can turn the card off in Customize).
struct ProviderInstanceRecord: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// An extra Claude Code config dir (`CLAUDE_CONFIG_DIR`-style home).
        case claudeConfigDir
        /// An extra Codex home (`CODEX_HOME`-style dir), credentials in `auth.json` or its keychain item.
        case codexHome
        /// A Claude Desktop / Cowork login whose identity differs from the CLI login. Credentials come
        /// from Claude Desktop's Safe Storage; usage logs from its Cowork session sandboxes.
        case claudeDesktop
        /// A parked claude-swap (`cswap`) slot: identity from the tool's per-slot config backup,
        /// credentials read-only from its vault (keychain service `claude-swap` / `.enc` file). The
        /// ACTIVE slot is never an instance — it is what the default card is showing.
        case claudeSwapSlot
    }

    /// The instance provider id (`claude@ab12cd34`) — the primary key everywhere.
    var id: String
    var baseProviderID: String
    /// Display ordinal: the default login is implicitly 1, extras start at 2 ("Claude 2").
    var ordinal: Int
    var kind: Kind
    /// The home dir this instance is anchored to (`nil` for `.claudeDesktop`).
    var anchorPath: String?
    /// For `.claudeConfigDir`: the literal `CLAUDE_CONFIG_DIR` string whose hash names the keychain
    /// item (`~/…` vs absolute matter — Claude Code hashes the literal env value).
    var keychainLiteral: String?
    /// For `.claudeDesktop` / `.claudeSwapSlot`: the organization UUID whose Desktop token can back
    /// this instance. Claude plans are org-scoped (a Team org can sit next to a personal Max org under
    /// one account), so the instance pins the org instead of following Desktop's active one.
    var desktopOrganization: String?
    /// For `.claudeSwapSlot`: the vault item's account attribute (`account-<N>-<email>`), which also
    /// derives the `.enc` file fallback name.
    var swapAccountName: String?
    /// Stable account identity: Claude `oauthAccount.accountUuid` plus `|organizationUuid` when an org
    /// is recorded (org-scoped plans), Codex `tokens.account_id`, or a path-derived key for
    /// keychain-mode Codex homes whose identity needs a secret read.
    var identityKey: String
    /// Human label for "which one is which" (account email, with the org name when present). Kept
    /// internal in Phase 1 — the UI shows only "Claude 2" — and surfaced in a later phase.
    var identityLabel: String?

    init(
        id: String,
        baseProviderID: String,
        ordinal: Int,
        kind: Kind,
        anchorPath: String?,
        keychainLiteral: String?,
        desktopOrganization: String? = nil,
        swapAccountName: String? = nil,
        identityKey: String,
        identityLabel: String?
    ) {
        self.id = id
        self.baseProviderID = baseProviderID
        self.ordinal = ordinal
        self.kind = kind
        self.anchorPath = anchorPath
        self.keychainLiteral = keychainLiteral
        self.desktopOrganization = desktopOrganization
        self.swapAccountName = swapAccountName
        self.identityKey = identityKey
        self.identityLabel = identityLabel
    }
}

/// A login found by `ProviderInstanceDiscovery` this launch, before reconciliation with the persisted
/// records assigns (or re-finds) its instance id and ordinal.
struct DiscoveredProviderInstance: Hashable, Sendable {
    var baseProviderID: String
    var kind: ProviderInstanceRecord.Kind
    var anchorPath: String?
    var keychainLiteral: String?
    var desktopOrganization: String? = nil
    var swapAccountName: String? = nil
    var identityKey: String
    var identityLabel: String?
}

/// Everything `ProviderCatalog` needs to build instance runtimes alongside the defaults. Assembled in
/// `AppContainer` from the discovery result; the one-shot CLI passes none and keeps default-only
/// behavior.
struct ProviderInstanceContext {
    var records: [ProviderInstanceRecord]
    /// Cowork session `.claude` dirs per `.claudeDesktop` instance id (that account's usage logs).
    var coworkRootsByInstanceID: [String: [URL]]
    /// When a `.claudeDesktop` instance exists, the default Claude card must scan only the Cowork dirs
    /// belonging to the default account (`nil` = no partition; keep the built-in walk untouched).
    var defaultClaudeCoworkRoots: [URL]?
    /// Swap machines: the account-activity timeline from cswap's switch history, plus the shared home
    /// roots it partitions and the default card's identity (its side of the partition).
    var claudeSwapTimeline: ClaudeSwapTimeline?
    var claudeSharedHomeRoots: [URL]
    var defaultClaudeIdentityKey: String?

    init(
        records: [ProviderInstanceRecord],
        coworkRootsByInstanceID: [String: [URL]] = [:],
        defaultClaudeCoworkRoots: [URL]? = nil,
        claudeSwapTimeline: ClaudeSwapTimeline? = nil,
        claudeSharedHomeRoots: [URL] = [],
        defaultClaudeIdentityKey: String? = nil
    ) {
        self.records = records
        self.coworkRootsByInstanceID = coworkRootsByInstanceID
        self.defaultClaudeCoworkRoots = defaultClaudeCoworkRoots
        self.claudeSwapTimeline = claudeSwapTimeline
        self.claudeSharedHomeRoots = claudeSharedHomeRoots
        self.defaultClaudeIdentityKey = defaultClaudeIdentityKey
    }

    func records(forBase baseProviderID: String) -> [ProviderInstanceRecord] {
        records.filter { $0.baseProviderID == baseProviderID }.sorted { $0.ordinal < $1.ordinal }
    }

    /// Display name by rank among the VISIBLE cards ("Claude 2", "Claude 3", …) — persisted ordinals
    /// stay the stable sort key but never show gaps: a suppressed record (its account currently the
    /// default login, common with swap tools) must not make the survivors read "Claude 1" + "Claude 3".
    func displayName(for record: ProviderInstanceRecord, baseName: String) -> String {
        let siblings = records(forBase: record.baseProviderID)
        let rank = (siblings.firstIndex { $0.id == record.id } ?? 0) + 2
        return "\(baseName) \(rank)"
    }

    /// The default card's display name gains its ordinal only when siblings exist ("Claude 1").
    func defaultDisplayName(forBase baseProviderID: String, name: String) -> String {
        records.contains { $0.baseProviderID == baseProviderID } ? "\(name) 1" : name
    }
}

/// Persists instance records (`openusage.providerInstances.v1`) and reconciles each launch's discovery
/// against them: an already-known identity keeps its id and ordinal (and refreshes its anchor/label),
/// a new identity appends with the next free ordinal. Phase 1 never removes records.
@MainActor
final class ProviderInstancesStore {
    private static let storageKey = "openusage.providerInstances.v1"

    private let defaults: UserDefaults
    private(set) var records: [ProviderInstanceRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ProviderInstanceRecord].self, from: data) {
            self.records = decoded
        } else {
            self.records = []
        }
    }

    @discardableResult
    func reconcile(with discovered: [DiscoveredProviderInstance]) -> [ProviderInstanceRecord] {
        var updated = records
        var changed = false
        for finding in discovered {
            let id = ProviderInstanceID.make(baseProviderID: finding.baseProviderID, identityKey: finding.identityKey)
            if let index = updated.firstIndex(where: { $0.id == id }) {
                // Known account: keep id + ordinal (layout stability), adopt the latest anchor/label —
                // the same account may have moved homes or refreshed its profile email.
                // Known account: id + ordinal are the stable half (layout stability); everything that
                // describes WHERE the account lives — kind, anchor, vault item, org — adopts the
                // latest discovery. A login can genuinely migrate sources (a Desktop-only org later
                // shows up as a cswap slot with a real CLI token; a home moves), and the freshest
                // source is the one that can actually fetch.
                var record = updated[index]
                let refreshed = ProviderInstanceRecord(
                    id: record.id,
                    baseProviderID: record.baseProviderID,
                    ordinal: record.ordinal,
                    kind: finding.kind,
                    anchorPath: finding.anchorPath,
                    keychainLiteral: finding.keychainLiteral,
                    desktopOrganization: finding.desktopOrganization,
                    swapAccountName: finding.swapAccountName,
                    identityKey: record.identityKey,
                    identityLabel: finding.identityLabel ?? record.identityLabel
                )
                if refreshed != record {
                    record = refreshed
                    updated[index] = record
                    changed = true
                }
            } else {
                let nextOrdinal = (updated.filter { $0.baseProviderID == finding.baseProviderID }
                    .map(\.ordinal).max() ?? 1) + 1
                updated.append(ProviderInstanceRecord(
                    id: id,
                    baseProviderID: finding.baseProviderID,
                    ordinal: nextOrdinal,
                    kind: finding.kind,
                    anchorPath: finding.anchorPath,
                    keychainLiteral: finding.keychainLiteral,
                    desktopOrganization: finding.desktopOrganization,
                    swapAccountName: finding.swapAccountName,
                    identityKey: finding.identityKey,
                    identityLabel: finding.identityLabel
                ))
                changed = true
                AppLog.info(.config, "discovered new \(finding.baseProviderID) login → instance \(id) (ordinal \(nextOrdinal))")
            }
        }
        if changed {
            records = updated
            persist()
        }
        return records
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-instance records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
