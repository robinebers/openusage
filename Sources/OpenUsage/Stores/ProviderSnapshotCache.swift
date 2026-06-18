import Foundation

struct ProviderSnapshotCache {
    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    /// A snapshot stays fresh for exactly one refresh interval, which is what lets cached data survive a
    /// relaunch without an immediate refetch and expire precisely when the next refresh is due. Tests
    /// inject a fixed TTL for a deterministic freshness window.
    private let ttl: TimeInterval
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        // v3: spend / Codex credits / rate-limit-resets rows moved from `.text` (a parsed display string)
        // to `.values` (raw numbers). Bumping the key drops pre-upgrade caches so the new `.values`-based
        // widgets never try to resolve a stale `.text` line — which would misread the fused string
        // (tokens tile showing the dollar amount, combined dropping tokens) until the first refresh.
        storageKey: String = "openusage.providerSnapshots.v3",
        ttl: TimeInterval = RefreshSetting.interval,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Every stored snapshot for the given providers, including expired ones. Display uses this
    /// (stale-while-revalidate: last-known values keep showing while a refresh runs); refresh gating
    /// still goes through the TTL-checked `snapshot(providerID:)`.
    func loadSnapshots(providerIDs: [String]) -> [String: ProviderSnapshot] {
        let providerIDSet = Set(providerIDs)
        let loaded = loadPayload().snapshots.filter { providerID, _ in
            providerIDSet.contains(providerID)
        }
        AppLog.debug(.cache, "loaded \(loaded.count) snapshots from disk")
        return loaded
    }

    func snapshot(providerID: String) -> ProviderSnapshot? {
        let snapshot = loadPayload().snapshots[providerID]
        guard let snapshot else { return nil }
        // Inlined the freshness check so the staleness can be logged (age vs ttl -> fresh|stale);
        // behavior is identical to the prior `isValid` helper.
        let age = now().timeIntervalSince(snapshot.refreshedAt)
        let fresh = age < ttl
        AppLog.debug(.cache, "\(providerID) staleness \(Int(age))s vs ttl \(Int(ttl))s -> \(fresh ? "fresh" : "stale")")
        return fresh ? snapshot : nil
    }

    func store(_ snapshot: ProviderSnapshot) {
        guard !snapshot.lines.contains(where: \.isError) else {
            AppLog.debug(.cache, "skip write \(snapshot.providerID) (error snapshot)")
            return
        }
        AppLog.debug(.cache, "write \(snapshot.providerID)")
        var payload = loadPayload()
        payload.snapshots[snapshot.providerID] = snapshot
        save(payload)
    }

    private func loadPayload() -> Payload {
        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            return Payload(snapshots: [:])
        }
        return payload
    }

    private func save(_ payload: Payload) {
        // Fail loudly: a swallowed encode error would silently drop a snapshot from the cache. No
        // behavior change (the write is still best-effort), but the failure is now visible.
        do {
            let data = try encoder.encode(payload)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            AppLog.warn(.cache, "encode failed, snapshot not persisted: \(error.localizedDescription)")
        }
    }
}
