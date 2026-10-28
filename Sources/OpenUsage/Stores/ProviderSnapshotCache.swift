import Foundation

/// The last good snapshot of every account, saved in the app's defaults under one key so a relaunch and
/// the `openusage` command show it before the first fetch. `WidgetDataStore` owns the snapshots and
/// decides which are fresh; this only reads and writes them.
struct ProviderSnapshotCache {
    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
    }

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(userDefaults: UserDefaults = .standard, storageKey: String = "openusage.providerSnapshots.v11") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    /// Every saved snapshot, expired ones included. Saved data that no longer decodes (a schema change, a
    /// half-written blob, a manual `defaults` edit) is logged and read as empty.
    func load() -> [String: ProviderSnapshot] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Payload.self, from: data).snapshots
        } catch {
            AppLog.warn(.cache, "cache decode failed, dropping stored snapshots: \(error.localizedDescription)")
            return [:]
        }
    }

    func save(_ snapshots: [String: ProviderSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            userDefaults.set(try encoder.encode(Payload(snapshots: snapshots)), forKey: storageKey)
        } catch {
            AppLog.warn(.cache, "encode failed, snapshot not persisted: \(error.localizedDescription)")
        }
    }
}
