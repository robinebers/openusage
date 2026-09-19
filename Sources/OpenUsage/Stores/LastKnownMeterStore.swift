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
/// a restored reading carries none: the bar and its percentage are exactly as true as when they were
/// captured, and the row is marked outdated so nothing here passes for current.
@MainActor
final class LastKnownMeterStore {
    private struct Reading: Codable {
        let used: Double
        let limit: Double
        let capturedAt: Date
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

    /// Remember a real bounded reading. Unbounded rows and no-data rows are ignored: there is no bar
    /// to restore for them.
    func record(_ data: WidgetData, for descriptorID: String) {
        guard data.hasData, let limit = data.limit, limit > 0, !data.isChart else { return }
        readings[descriptorID] = Reading(used: data.used, limit: limit, capturedAt: now())
        persist()
    }

    /// The stored reading applied back onto `sample`, or `nil` when nothing usable is stored. The
    /// result is flagged `isOutdated` so every surface can show it as the aged figure it is.
    func restore(onto sample: WidgetData, for descriptorID: String) -> WidgetData? {
        guard let reading = readings[descriptorID],
              now().timeIntervalSince(reading.capturedAt) < Self.maximumAge else { return nil }
        var result = sample
        result.hasData = true
        result.used = reading.used
        result.limit = reading.limit
        result.resetsAt = nil
        result.expiriesAt = []
        result.isOutdated = true
        return result
    }

    /// Drops everything, for "Reset All Settings".
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
