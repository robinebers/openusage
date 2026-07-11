import Foundation
import Observation

/// One persisted additional Claude account. The default account (`~/.claude` / the bare keychain
/// service) is NEVER stored here — it is always provider id `"claude"`. Only extra accounts get a
/// record, a stable UUID, and provider id `"claude.<uuid>"`.
struct ClaudeAccountRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var configDirPath: String?
    var keychainService: String?
    /// User-supplied display name. `nil` falls back to a short id-derived name.
    var customName: String?

    var scope: ClaudeAccountScope {
        ClaudeAccountScope(configDir: configDirPath, keychainService: keychainService)
    }

    /// Provider id for this account's `ClaudeProvider` instance and its widgets.
    var providerID: String { "claude.\(id.uuidString.lowercased())" }

    /// Shown name: the custom name when set, else "Claude (<first 8 of uuid>)".
    var displayName: String {
        if let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return "Claude (\(String(id.uuidString.lowercased().prefix(8))))"
    }

    func makeProvider() -> Provider {
        Provider(
            id: providerID,
            displayName: displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    /// Whether a freshly discovered account refers to this same record (shared config dir or keychain
    /// service). Used at launch to keep a record's UUID stable so its layout/enablement survives.
    func matches(_ account: DiscoveredClaudeAccount) -> Bool {
        if let dir = account.configDir, dir == configDirPath { return true }
        if let service = account.keychainService, service == keychainService { return true }
        return false
    }

    /// Whether every credential source this record carries is also carried by `other` (which must share
    /// at least one of them), so `other` now fully represents this account and this record is a stale
    /// duplicate. Used to collapse a file-only + keychain-only pair once discovery links them into one.
    func isSubsumed(by other: ClaudeAccountRecord) -> Bool {
        guard id != other.id else { return false }
        var sharesSource = false
        if let dir = configDirPath {
            guard dir == other.configDirPath else { return false }
            sharesSource = true
        }
        if let service = keychainService {
            guard service == other.keychainService else { return false }
            sharesSource = true
        }
        return sharesSource
    }
}

/// Persists the set of additional Claude accounts and reconciles it against on-machine discovery at
/// launch. Records whose sources have vanished are kept (so a user's layout/rename isn't silently
/// dropped) and still instantiated — their provider simply surfaces "not signed in" on refresh.
@MainActor
@Observable
final class ClaudeAccountsStore {
    static let storageKey = "openusage.claudeAccounts.v1"

    private let defaults: UserDefaults
    private(set) var records: [ClaudeAccountRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.records = Self.load(from: defaults)
    }

    /// Merge discovery into the stored set: matched accounts keep their UUID (refreshing their source
    /// fields in case a keychain service appeared for a previously file-only dir, or vice versa); newly
    /// discovered accounts get a fresh UUID. Existing records with no match are kept as-is.
    @discardableResult
    func reconcile(with discovered: [DiscoveredClaudeAccount]) -> [ClaudeAccountRecord] {
        var merged = records
        for account in discovered {
            if let index = merged.firstIndex(where: { $0.matches(account) }) {
                if let dir = account.configDir { merged[index].configDirPath = dir }
                if let service = account.keychainService { merged[index].keychainService = service }
                Self.collapseSubsumedRecords(into: index, in: &merged)
            } else {
                merged.append(ClaudeAccountRecord(
                    id: UUID(),
                    configDirPath: account.configDir,
                    keychainService: account.keychainService,
                    customName: nil
                ))
            }
        }
        records = merged
        persist()
        return merged
    }

    /// After a matched record absorbed a newly discovered source, drop any other record whose sources are
    /// now fully represented by it — the file-only + keychain-only split that discovery has resolved into
    /// one account. `firstIndex` matches the oldest record, so the survivor already keeps the older UUID;
    /// if it has no custom name it adopts one from a collapsed record so a user's rename isn't lost.
    private static func collapseSubsumedRecords(into index: Int, in records: inout [ClaudeAccountRecord]) {
        let survivor = records[index]
        var adoptedName = survivor.customName
        records.removeAll { record in
            guard record.isSubsumed(by: survivor) else { return false }
            if adoptedName == nil { adoptedName = record.customName }
            return true
        }
        if let survivorIndex = records.firstIndex(where: { $0.id == survivor.id }) {
            records[survivorIndex].customName = adoptedName
        }
    }

    func record(forProviderID providerID: String) -> ClaudeAccountRecord? {
        records.first { $0.providerID == providerID }
    }

    /// Set (or clear) a custom name. This store is `@Observable`, and `AppContainer` wires a name-override
    /// closure into `LayoutStore` that reads it on every render, so the change applies live wherever the
    /// account name shows — no relaunch. See `AppContainer.renameClaudeAccount`.
    func setCustomName(_ name: String?, forID id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index].customName = (trimmed?.isEmpty == false) ? trimmed : nil
        persist()
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(records), forKey: Self.storageKey)
        } catch {
            AppLog.error(.config, "failed to persist Claude accounts: \(error.localizedDescription)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [ClaudeAccountRecord] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([ClaudeAccountRecord].self, from: data)
        } catch {
            AppLog.error(.config, "failed to load Claude accounts: \(error.localizedDescription)")
            return []
        }
    }
}
