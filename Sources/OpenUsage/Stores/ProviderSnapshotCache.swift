import Foundation
import os

struct ProviderSnapshotCache {
    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
    }

    /// In-memory mirror of the persisted blob. Reads (`snapshot`, `loadSnapshots`, and the read inside
    /// `store`) hit this instead of re-decoding the whole all-providers JSON from `UserDefaults` on
    /// every call — a refresh pass otherwise paid O(N) full decodes (plus O(N) encodes) per pass on the
    /// MainActor. The blob is decoded at most once per cache instance (first access); writes update the
    /// mirror and persist through. Lock-backed so the value-type cache memoizes across calls and stays
    /// safe to share.
    private let memo = OSAllocatedUnfairLock<Payload?>(initialState: nil)

    /// Provider IDs whose snapshot was written by `store` *during this cache instance's lifetime* (i.e.
    /// this running session). The freshness gate (`snapshot(providerID:)`) trusts a snapshot only when
    /// its provider is in here — so a snapshot loaded from disk on launch is shown (via `loadSnapshots`)
    /// but never counts as fresh, forcing one refresh on the first post-launch pass. Lock-backed for the
    /// same reason as `memo`: the value-type cache shares it across copies and stays safe. See #697.
    private let sessionWrites = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private let userDefaults: UserDefaults
    private let storageKey: String
    /// A snapshot written this session stays fresh for exactly one refresh interval, then expires so the
    /// periodic loop refetches on schedule. A snapshot loaded from a *previous* session (off disk) is never
    /// fresh regardless of its `refreshedAt` — see `sessionWrites`. Tests inject a fixed TTL for a
    /// deterministic freshness window.
    private let ttl: TimeInterval
    /// The menu-bar app deliberately refreshes once per launch, even when its persisted snapshot is
    /// young. A one-shot reader has no meaningful session, so it opts into timestamp-only freshness.
    private let allowsPersistedFreshness: Bool
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        // v3: spend / Codex credits / rate-limit-resets rows moved from `.text` (a parsed display string)
        // to `.values` (raw numbers). Bumping the key drops pre-upgrade caches so the new `.values`-based
        // widgets never try to resolve a stale `.text` line — which would misread the fused string
        // (tokens tile showing the dollar amount, combined dropping tokens) until the first refresh.
        // v4/v5: `.values` rows gained Codex reset-credit expiry data — v4 carried a single `resetsAt`,
        // v5 replaced it with an `expiriesAt` list (one per available credit, shown in the row's
        // tooltip). Old payloads decode cleanly (the absent key → empty list), but the bump refetches
        // once so the expiries show immediately on upgrade instead of after the cached snapshot expires.
        // v6: `.values` rows gained `unknownModels` (Cursor spend tiles list the unpriced models behind a
        // warning triangle). Same story — old payloads decode with an empty list, the bump just refetches
        // once so the warning shows immediately instead of after the cached snapshot expires.
        // v7: spend `.values` rows gained `modelBreakdown` for the per-model hover panel. Old payloads
        // decode cleanly without it, but the bump fetches fresh snapshots so hover panels appear right away.
        // v8: provider snapshots gained normalized daily history for iCloud aggregation. Refetch on
        // upgrade so enabling sync can publish a complete first document immediately.
        storageKey: String = "openusage.providerSnapshots.v8",
        ttl: TimeInterval = RefreshSetting.interval,
        allowsPersistedFreshness: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.allowsPersistedFreshness = allowsPersistedFreshness
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
        // Freshness has two requirements, and disk age alone is not enough: the snapshot must have been
        // written *this session* AND still be within TTL. A snapshot served from a previous session's
        // persisted blob is shown for instant paint but never gates a refresh, so every launch refetches
        // promptly instead of waiting out the previous session's remaining interval (#697).
        let writtenThisSession = sessionWrites.withLock { $0.contains(providerID) }
        let age = now().timeIntervalSince(snapshot.refreshedAt)
        let trusted = allowsPersistedFreshness || writtenThisSession
        let fresh = trusted && age < ttl
        let reason = !trusted ? "stale (not written this session)"
            : fresh ? "fresh" : "stale"
        AppLog.debug(.cache, "\(providerID) staleness \(Int(age))s vs ttl \(Int(ttl))s -> \(reason)")
        return fresh ? snapshot : nil
    }

    func store(_ snapshot: ProviderSnapshot) {
        guard !snapshot.lines.contains(where: \.isError) else {
            AppLog.debug(.cache, "skip write \(snapshot.providerID) (error snapshot)")
            return
        }
        AppLog.debug(.cache, "write \(snapshot.providerID)")
        // Mark this provider as written *this session* so its snapshot now satisfies the freshness gate
        // (a launch-loaded snapshot never does — see `sessionWrites`).
        sessionWrites.withLock { $0.insert(snapshot.providerID) }
        var payload = loadPayload()
        payload.snapshots[snapshot.providerID] = snapshot
        save(payload)
    }

    private func loadPayload() -> Payload {
        if let mirror = memo.withLock({ $0 }) { return mirror }
        // First access only: decode the persisted blob once, then mirror it. (Decoding outside the
        // lock keeps `self` out of the `@Sendable` closure; cache access is MainActor-serialized in
        // production, so the worst a race could do is decode twice into the same value — harmless.)
        let loaded = decodeStoredPayload()
        memo.withLock { $0 = loaded }
        return loaded
    }

    private func decodeStoredPayload() -> Payload {
        // No stored data is the legitimate first-launch / cleared-cache case — recover to empty
        // silently. Data present but undecodable is a real problem (post-upgrade schema drift, a
        // half-written blob, a manual `defaults` edit): fail loudly, then recover to empty. A silent
        // drop here empties ALL providers' caches at once and feeds the refresh storm. Mirrors the
        // loud `save` path above. Runs at most once per cache instance (then memoized).
        guard let data = userDefaults.data(forKey: storageKey) else {
            return Payload(snapshots: [:])
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            AppLog.warn(.cache, "cache decode failed, dropping stored snapshots: \(error.localizedDescription)")
            return Payload(snapshots: [:])
        }
    }

    private func save(_ payload: Payload) {
        // Update the in-memory mirror first so subsequent reads see this write even if the encode
        // below fails (the running session stays correct; only persistence is best-effort).
        memo.withLock { $0 = payload }
        // Fail loudly: a swallowed encode error would silently drop a snapshot from the persisted
        // cache. No behavior change (the write is still best-effort), but the failure is now visible.
        do {
            let data = try encoder.encode(payload)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            AppLog.warn(.cache, "encode failed, snapshot not persisted: \(error.localizedDescription)")
        }
    }
}
