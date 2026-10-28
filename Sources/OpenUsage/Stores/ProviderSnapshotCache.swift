import Foundation

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
