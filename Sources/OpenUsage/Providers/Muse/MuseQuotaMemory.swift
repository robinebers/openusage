import Foundation

/// Blocked-window attribution for Muse 429s, shared with the Go TUI/daemon.
///
/// A 429 body carries only a reset instant — no window marker — so without
/// memory every block looks like the week (the card once showed "Weekly:
/// Limit reached" with a 4-hour reset, which is a session window). The last
/// successful subscription payload is persisted to the same state file Go
/// uses, so both apps share attribution memory and a restart mid-block
/// still classifies. All file I/O is best-effort and never throws: a missing
/// or unreadable file just means the legacy weekly assumption.
struct MuseQuotaMemory: Sendable, Equatable {
    static let fileName = "muse-quota-memory.json"
    static let schemaVersion = 2
    /// A 429 reset this much sooner than the remembered weekly reset belongs
    /// to the session window. Windows run 5h; weekly resets sit days out, so
    /// 6h has wide margin. Mirrors Go's `sessionResetAmbiguity`.
    static let sessionResetAmbiguity: TimeInterval = 6 * 3_600

    var weeklyUsed: Double? = nil
    var weeklyResetUnix: Int64? = nil
    var windowUsed: Double? = nil
    var windowResetUnix: Int64? = nil
    var tier: String? = nil
    var observedAtUnix: Int64? = nil

    /// State dir honoring XDG_STATE_HOME, else `~/.local/state/openusage` —
    /// the same resolution as Go's `telemetry.DefaultStateDir`.
    static func stateDirectory(environment: [String: String], home: URL) -> URL {
        if let base = environment["XDG_STATE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !base.isEmpty {
            return URL(fileURLWithPath: base).appendingPathComponent("openusage")
        }
        return home
            .appendingPathComponent(".local")
            .appendingPathComponent("state")
            .appendingPathComponent("openusage")
    }

    static func fileURL(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent(fileName)
    }

    /// Snapshot of a successful payload. Nil unless the weekly reset is known —
    /// without it there is nothing to attribute a later 429 against.
    static func fromUsage(_ usage: MuseQuotaUsage, now: Date) -> MuseQuotaMemory? {
        guard let weeklyReset = usage.weeklyResetsAt else { return nil }
        return MuseQuotaMemory(
            weeklyUsed: usage.weeklyUsedPercent,
            weeklyResetUnix: Int64(weeklyReset.timeIntervalSince1970),
            windowUsed: usage.windowUsedPercent,
            windowResetUnix: usage.windowResetsAt.map { Int64($0.timeIntervalSince1970) },
            tier: usage.tier,
            observedAtUnix: Int64(now.timeIntervalSince1970)
        )
    }

    /// True when the 429 reset belongs to the session window. False means
    /// weekly (or unknown): the legacy assumption.
    static func isSessionBlock(resetsAt: Date, now: Date, memory: MuseQuotaMemory?) -> Bool {
        guard let memory,
              let weeklyResetUnix = memory.weeklyResetUnix, weeklyResetUnix > 0
        else {
            return false
        }
        let weeklyReset = Date(timeIntervalSince1970: TimeInterval(weeklyResetUnix))
        guard now < weeklyReset else { return false } // memory expired with the old week
        return weeklyReset.timeIntervalSince(resetsAt) > sessionResetAmbiguity
    }

    func save(to fileURL: URL) {
        // Absent keys are omitted (both readers tolerate that); encoding a
        // nil optional as `Any` would fail serialization and drop the write.
        var object: [String: Any] = ["schema_version": Self.schemaVersion]
        if let weeklyUsed { object["weekly_used"] = weeklyUsed }
        if let weeklyResetUnix { object["weekly_reset_unix"] = weeklyResetUnix }
        if let windowUsed { object["window_used"] = windowUsed }
        if let windowResetUnix { object["window_reset_unix"] = windowResetUnix }
        if let tier { object["tier"] = tier }
        if let observedAtUnix { object["observed_at_unix"] = observedAtUnix }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Atomic write then 0600: the payload carries usage levels, not keys,
        // but the state dir convention is locked-down files.
        _ = try? data.write(to: fileURL, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Schema is additive: files written before the window fields existed
    /// simply lack them and still carry the week.
    static func load(from fileURL: URL) -> MuseQuotaMemory? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let weeklyReset = number(json["weekly_reset_unix"]).map(Int64.init),
              weeklyReset > 0
        else {
            return nil
        }
        let tier = (json["tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MuseQuotaMemory(
            weeklyUsed: number(json["weekly_used"]),
            weeklyResetUnix: weeklyReset,
            windowUsed: number(json["window_used"]),
            windowResetUnix: number(json["window_reset_unix"]).map(Int64.init),
            tier: tier?.isEmpty == true ? nil : tier,
            observedAtUnix: number(json["observed_at_unix"]).map(Int64.init)
        )
    }
}
