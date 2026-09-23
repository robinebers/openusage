import Foundation

/// The last real reading each bounded metric had, so a provider that temporarily cannot answer keeps
/// showing its bars instead of collapsing to "No data".
///
/// Claude's usage endpoint rate-limits aggressively, and a rate-limited card reports a status line
/// with no meters at all. The provider keeps its own last-good copy in memory, which the next relaunch
/// loses, so a restart during a rate-limit window left the card blank. This store is that memory,
/// written to disk.
///
/// Only `used` and `limit` are kept. A reset date would age into a countdown that runs backwards, so
/// a restored reading carries no timing at all: the bar and its percentage are exactly as true as when
/// they were captured, and the row is marked outdated so nothing here passes for current.
///
/// Each reading also carries the account that produced it and the time of that measurement, so the
/// same ownership rule as the snapshot cache applies, and reading an old snapshot never renews it.
@MainActor
final class LastKnownMeterStore {
    private struct Reading: Codable, Equatable {
        let used: Double
        let limit: Double
        /// When the provider measured it (the snapshot's refresh time), not when it was displayed.
        let capturedAt: Date
        /// The card's account identity at capture, `nil` for providers without one.
        let identityKey: String?
    }

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private var readings: [String: Reading]

    /// Past this age a reading stops being a useful stand-in and the row goes back to "No data";
    /// a week-old percentage of a five-hour window would be fiction. Matches the longest window any
    /// provider reports on.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// How far a stand-in reading recedes. Enough to read as "not current" beside a live bar, still
    /// legible on its own.
    static let outdatedOpacity: Double = 0.45

    init(defaults: UserDefaults = .standard,
         key: String = "openusage.lastKnownMeters.v1",
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Reading].self, from: data) {
            self.readings = decoded
        } else {
            self.readings = [:]
        }
    }

    /// Remember a real bounded reading measured at `capturedAt` by the account `identityKey`.
    /// Unbounded rows and no-data rows are ignored: there is no bar to restore for them. Called on
    /// every render, so an unchanged or older reading writes nothing.
    func record(_ data: WidgetData, for descriptorID: String, capturedAt: Date, identityKey: String?) {
        guard data.hasData, let limit = data.limit, limit > 0, !data.isChart else { return }
        let reading = Reading(used: data.used, limit: limit, capturedAt: capturedAt, identityKey: identityKey)
        if let stored = readings[descriptorID],
           stored == reading || (stored.capturedAt > capturedAt && stored.identityKey == identityKey) {
            return
        }
        readings[descriptorID] = reading
        persist()
    }

    /// The stored reading applied back onto `sample`, or `nil` when nothing usable is stored. The
    /// result is flagged `isOutdated` so every surface can show it as the aged figure it is.
    ///
    /// Ownership follows the snapshot cache's launch guard: when the card's current account is known,
    /// only a reading that account produced may stand in. An unresolved current account can't verify
    /// either way, so it keeps the reading, as the cache does.
    func restore(onto sample: WidgetData, for descriptorID: String, identityKey: String?) -> WidgetData? {
        guard let reading = readings[descriptorID],
              now().timeIntervalSince(reading.capturedAt) < Self.maximumAge else { return nil }
        if let identityKey, reading.identityKey != identityKey { return nil }
        var result = sample
        result.hasData = true
        result.used = reading.used
        result.limit = reading.limit
        // The current window is unknown, so drop every timing claim: no reset date or expiries, no
        // cycle length ("Resets in 30d"), and no session-start signal ("Not started").
        result.resetsAt = nil
        result.expiriesAt = []
        result.periodDurationMs = nil
        result.sessionStartSignal = nil
        result.isOutdated = true
        return result
    }

    /// Drops the readings for metrics a provider's successful response no longer reports.
    func forget(_ descriptorIDs: [String]) {
        let count = readings.count
        for id in descriptorIDs { readings[id] = nil }
        if readings.count != count { persist() }
    }

    /// Drops every stored reading.
    func clear() {
        readings = [:]
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(readings), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist last-known meters: \(error.localizedDescription)")
        }
    }
}
