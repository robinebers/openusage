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

    /// Identity for a home whose account can't be read without a keychain secret (keyring-mode Codex):
    /// keyed on a SHA-256 fingerprint of the canonical home path until a refresh reveals the real
    /// account. The raw path must never enter the record's identity field because that field can be
    /// included in the private iCloud usage document (the local-only anchor remains a real path).
    static let pathDerivedIdentityPrefix = "codex-home:"

    static func pathDerivedIdentityKey(forCanonicalHome path: String) -> String {
        pathDerivedIdentityPrefix + hashHex(canonicalHomePath(path))
    }

    static func isPathDerivedKey(_ identityKey: String) -> Bool {
        identityKey.hasPrefix(pathDerivedIdentityPrefix)
    }

    /// Whether a path-derived identity is already in the opaque v1 representation. Early builds of
    /// provider instances stored the raw path after the prefix; persisted records migrate on load.
    static func isOpaquePathDerivedKey(_ identityKey: String) -> Bool {
        guard isPathDerivedKey(identityKey) else { return false }
        let suffix = identityKey.dropFirst(pathDerivedIdentityPrefix.count)
        return suffix.count == 64 && suffix.allSatisfy { $0.isHexDigit }
    }

    static func canonicalHomePath(_ path: String) -> String {
        URL(fileURLWithPath: expandHome(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func hashHex(_ value: String) -> String {
        SHA256.hash(data: Data(value.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
    /// A stale anchored record can temporarily describe the same account as another card after that
    /// account moves homes. Keep the record so its anchor can reclaim the same layout id later, but
    /// omit it from runtimes while this points at the card currently representing the identity.
    var duplicateOfID: String?

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
        identityLabel: String?,
        duplicateOfID: String? = nil
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
        self.duplicateOfID = duplicateOfID
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

/// Everything `ProviderCatalog` needs to build instance runtimes alongside the defaults. The shared
/// `ProviderRuntimeAssembly` creates it from discovery for both the app and one-shot CLI.
struct ProviderInstanceContext {
    var records: [ProviderInstanceRecord]
    /// Additional Claude usage roots per instance id. These include Cowork sandboxes and same-account
    /// sibling config homes; credentials remain pinned to the record's preferred source.
    var coworkRootsByInstanceID: [String: [URL]]
    /// Same-account sibling config homes for the default Claude card. Scanned separately and merged
    /// without changing the standard auth store's credential precedence.
    var defaultClaudeAdditionalLogRoots: [URL]
    /// Explicit default roots only when implicit XDG/standard roots belong to different accounts.
    /// `nil` preserves the historical scanner resolution.
    var defaultClaudeLogRoots: [URL]?
    /// When a `.claudeDesktop` instance exists, the default Claude card must scan only the Cowork dirs
    /// belonging to the default account (`nil` = no partition; keep the built-in walk untouched).
    var defaultClaudeCoworkRoots: [URL]?
    /// Canonical Codex credential home → every verified same-account log root. The auth store still
    /// selects and rotates exactly one home/item; the scanner consults this map only after that home
    /// successfully authenticates.
    var codexRelatedLogRootsByHome: [String: [URL]]
    /// Swap machines: the account-activity timeline from cswap's switch history, plus the shared home
    /// roots it partitions and the default card's identity (its side of the partition).
    var claudeSwapTimeline: ClaudeSwapTimeline?
    var claudeSharedHomeRoots: [URL]
    var defaultClaudeIdentityKey: String?

    init(
        records: [ProviderInstanceRecord],
        coworkRootsByInstanceID: [String: [URL]] = [:],
        defaultClaudeAdditionalLogRoots: [URL] = [],
        defaultClaudeLogRoots: [URL]? = nil,
        defaultClaudeCoworkRoots: [URL]? = nil,
        codexRelatedLogRootsByHome: [String: [URL]] = [:],
        claudeSwapTimeline: ClaudeSwapTimeline? = nil,
        claudeSharedHomeRoots: [URL] = [],
        defaultClaudeIdentityKey: String? = nil
    ) {
        self.records = records
        self.coworkRootsByInstanceID = coworkRootsByInstanceID
        self.defaultClaudeAdditionalLogRoots = defaultClaudeAdditionalLogRoots
        self.defaultClaudeLogRoots = defaultClaudeLogRoots
        self.defaultClaudeCoworkRoots = defaultClaudeCoworkRoots
        self.codexRelatedLogRootsByHome = codexRelatedLogRootsByHome
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
/// against them: an already-known identity or exclusive anchored home keeps its id and ordinal, while
/// the record's account identity follows a real re-login. A genuinely new source appends with the next
/// free ordinal. Phase 1 never removes records.
@MainActor
final class ProviderInstancesStore {
    static let storageKey = "openusage.providerInstances.v1"

    private let defaults: UserDefaults
    private(set) var records: [ProviderInstanceRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ProviderInstanceRecord].self, from: data) {
            let migrated = decoded.map { record in
                guard ProviderInstanceID.isPathDerivedKey(record.identityKey),
                      !ProviderInstanceID.isOpaquePathDerivedKey(record.identityKey),
                      let anchorPath = record.anchorPath
                else { return record }
                var sanitized = record
                sanitized.identityKey = ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: anchorPath)
                return sanitized
            }
            self.records = migrated
            if migrated != decoded, let sanitized = try? JSONEncoder().encode(migrated) {
                defaults.set(sanitized, forKey: Self.storageKey)
                AppLog.info(.config, "migrated provider-instance home identities to opaque fingerprints")
            }
        } else {
            self.records = []
        }
    }

    @discardableResult
    func reconcile(
        with discovered: [DiscoveredProviderInstance],
        anchoredUpdates: [DiscoveredProviderInstance] = []
    ) -> [ProviderInstanceRecord] {
        var updated = records
        var discoveredRecordIDs: Set<String> = []
        var changed = false

        // Folded/default findings carry identity corrections for an existing exclusive anchor only.
        // Apply them before primary findings and preserve the record's credential-source metadata, so
        // a folded config root can never demote a same-account cswap vault chosen as authoritative.
        for finding in anchoredUpdates {
            guard let index = Self.anchoredMatchIndex(for: finding, in: updated) else { continue }
            var record = updated[index]
            let identity = ProviderInstanceID.isPathDerivedKey(finding.identityKey)
                && !ProviderInstanceID.isPathDerivedKey(record.identityKey)
                ? record.identityKey
                : finding.identityKey
            let label = identity == record.identityKey
                ? finding.identityLabel ?? record.identityLabel
                : finding.identityLabel
            if identity != record.identityKey || label != record.identityLabel {
                record.identityKey = identity
                record.identityLabel = label
                updated[index] = record
                changed = true
                AppLog.info(.config, "instance \(record.id): anchored account identity changed")
            }
        }

        for finding in discovered {
            if let index = Self.matchIndex(for: finding, in: updated) {
                // Known account (or the same anchored home across an identity-readability change):
                // id + ordinal are the stable half (layout stability); everything that describes
                // WHERE the account lives — kind, anchor, vault item, org — adopts the latest
                // discovery. A login can genuinely migrate sources (a Desktop-only org later shows
                // up as a cswap slot with a real CLI token; a home moves), and the freshest source
                // is the one that can actually fetch.
                var record = updated[index]
                // The id + ordinal belong to the card and never change. Its identity describes the
                // account currently occupying that source: any readable account replaces the old
                // identity (including an A → B re-login in one home), while a temporarily unreadable
                // keyring finding cannot erase a real identity learned on an earlier refresh.
                let upgradedIdentity = ProviderInstanceID.isPathDerivedKey(finding.identityKey)
                    && !ProviderInstanceID.isPathDerivedKey(record.identityKey)
                    ? record.identityKey
                    : finding.identityKey
                if upgradedIdentity != record.identityKey {
                    AppLog.info(.config, "instance \(record.id): anchored account identity changed")
                }
                let refreshedLabel = upgradedIdentity == record.identityKey
                    ? finding.identityLabel ?? record.identityLabel
                    : finding.identityLabel
                let refreshed = ProviderInstanceRecord(
                    id: record.id,
                    baseProviderID: record.baseProviderID,
                    ordinal: record.ordinal,
                    kind: finding.kind,
                    anchorPath: finding.anchorPath,
                    keychainLiteral: finding.keychainLiteral,
                    desktopOrganization: finding.desktopOrganization,
                    swapAccountName: finding.swapAccountName,
                    identityKey: upgradedIdentity,
                    identityLabel: refreshedLabel,
                    duplicateOfID: nil
                )
                discoveredRecordIDs.insert(record.id)
                if refreshed != record {
                    record = refreshed
                    updated[index] = record
                    changed = true
                }
            } else {
                let id = Self.availableID(for: finding, in: updated)
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
                discoveredRecordIDs.insert(id)
                changed = true
                AppLog.info(.config, "discovered new \(finding.baseProviderID) login → instance \(id) (ordinal \(nextOrdinal))")
            }
        }
        let reconciled = Self.suppressDuplicateIdentities(
            in: updated,
            preferring: discoveredRecordIDs
        )
        if reconciled != updated {
            updated = reconciled
            changed = true
        }
        if changed {
            records = updated
            persist()
        }
        return records.filter { $0.duplicateOfID == nil }
    }

    /// An anchored A → B re-login deliberately keeps A's card id, but B may already have a retained
    /// record at a now-absent home. Prefer the record observed this launch and suppress its stale
    /// identity peer. Suppression is persisted instead of deleting the peer: if either account later
    /// returns to that anchor, it reuses the same card id and layout rather than minting another one.
    private static func suppressDuplicateIdentities(
        in records: [ProviderInstanceRecord],
        preferring discoveredRecordIDs: Set<String>
    ) -> [ProviderInstanceRecord] {
        struct Identity: Hashable {
            let baseProviderID: String
            let identityKey: String
        }

        let groupedIndices = Dictionary(grouping: records.indices) { index in
            Identity(
                baseProviderID: records[index].baseProviderID,
                identityKey: records[index].identityKey
            )
        }
        var reconciled = records
        for indices in groupedIndices.values {
            guard indices.count > 1 else {
                // A tombstone becomes live again only when discovery actually sees its source. Merely
                // becoming identity-unique because another anchor changed must not resurrect a stale
                // runtime for an absent home.
                if let index = indices.first,
                   discoveredRecordIDs.contains(records[index].id),
                   reconciled[index].duplicateOfID != nil {
                    reconciled[index].duplicateOfID = nil
                }
                continue
            }

            // A currently discovered anchor beats stale state. If discovery itself contains the same
            // identity twice, or persisted state was already ambiguous, ordinal then id makes the
            // owner deterministic across launches.
            let discovered = indices.filter { discoveredRecordIDs.contains(records[$0].id) }
            let unsuppressed = indices.filter { records[$0].duplicateOfID == nil }
            let candidates = discovered.isEmpty
                ? (unsuppressed.isEmpty ? indices : unsuppressed)
                : discovered
            let ownerIndex = candidates.min { lhs, rhs in
                let left = records[lhs]
                let right = records[rhs]
                return left.ordinal == right.ordinal ? left.id < right.id : left.ordinal < right.ordinal
            }!
            let ownerID = records[ownerIndex].id

            for index in indices {
                let duplicateOfID = index == ownerIndex ? nil : ownerID
                if reconciled[index].duplicateOfID != duplicateOfID {
                    reconciled[index].duplicateOfID = duplicateOfID
                    if let duplicateOfID {
                        AppLog.info(
                            .config,
                            "instance \(records[index].id) suppressed: identity is shown by \(duplicateOfID)"
                        )
                    }
                }
            }
        }
        return reconciled
    }

    /// Match a finding to its record by an exclusive anchored home first, then current identity.
    /// A record's id intentionally does not change when a path identity becomes readable or account A
    /// is replaced by B, so comparing only the newly computed id cannot find it on the next launch.
    /// Claude config dirs and Codex homes each represent exactly one card per canonical anchor; cswap
    /// slots deliberately do not use anchor matching because every slot shares the same vault root.
    private static func matchIndex(
        for finding: DiscoveredProviderInstance,
        in records: [ProviderInstanceRecord]
    ) -> Int? {
        if let anchored = anchoredMatchIndex(for: finding, in: records) { return anchored }
        if let identity = records.firstIndex(where: {
            $0.baseProviderID == finding.baseProviderID && $0.identityKey == finding.identityKey
        }) { return identity }
        return nil
    }

    private static func anchoredMatchIndex(
        for finding: DiscoveredProviderInstance,
        in records: [ProviderInstanceRecord]
    ) -> Int? {
        guard (finding.kind == .claudeConfigDir || finding.kind == .codexHome),
              let findingAnchor = finding.anchorPath
        else { return nil }
        let findingCanonical = canonicalPath(findingAnchor)
        return records.firstIndex { record in
            guard record.baseProviderID == finding.baseProviderID,
                  record.kind == finding.kind,
                  let recordAnchor = record.anchorPath
            else { return false }
            return canonicalPath(recordAnchor) == findingCanonical
        }
    }

    /// Normally the identity-derived id is free. A card that kept its id across an A → B re-login can
    /// still occupy A's preferred id if account A later appears in a second home, so derive a stable
    /// collision id from A plus the new opaque home fingerprint instead of stealing B's existing card.
    private static func availableID(
        for finding: DiscoveredProviderInstance,
        in records: [ProviderInstanceRecord]
    ) -> String {
        let preferred = ProviderInstanceID.make(
            baseProviderID: finding.baseProviderID,
            identityKey: finding.identityKey
        )
        guard records.contains(where: { $0.id == preferred }) else { return preferred }

        let sourceKey = finding.anchorPath.map {
            ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: $0)
        } ?? finding.kind.rawValue
        var attempt = 0
        while true {
            let disambiguated = ProviderInstanceID.make(
                baseProviderID: finding.baseProviderID,
                identityKey: "\(finding.identityKey)|\(sourceKey)|\(attempt)"
            )
            if !records.contains(where: { $0.id == disambiguated }) { return disambiguated }
            attempt += 1
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        ProviderInstanceID.canonicalHomePath(path)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-instance records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
