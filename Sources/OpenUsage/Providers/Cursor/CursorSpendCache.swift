import Foundation

/// One closed-open coverage slice, except a slice that ends at the refresh's `now`, which includes
/// its endpoint so a row stamped at the download time is kept.
struct CursorSpendInterval: Codable, Sendable, Equatable {
    var start: Date
    var end: Date
}

/// A parsed Cursor export row with the fields spend tiles need. Dollars are priced again on read.
struct CursorSpendCachedRow: Codable, Sendable, Equatable {
    var date: Date
    var model: String
    var input: Int
    var cacheWrite5m: Int
    var cacheRead: Int
    var output: Int

    var tokens: TokenBreakdown {
        TokenBreakdown(
            input: input,
            cacheWrite5m: cacheWrite5m,
            cacheRead: cacheRead,
            output: output
        )
    }
}

struct CursorSpendCacheSnapshot: Codable, Sendable, Equatable {
    var rows: [CursorSpendCachedRow]
    var covered: [CursorSpendInterval]
    /// The next download after a timeout. Preferred over a fresh backfill so a long day gets smaller
    /// instead of being requested in full again.
    var retry: CursorSpendInterval?

    static let empty = CursorSpendCacheSnapshot(rows: [], covered: [], retry: nil)
}

/// Picks one CSV window per refresh and merges that window into the cached rows.
enum CursorSpendPlanner {
    static let overlap: TimeInterval = 6 * 60 * 60
    static let retention: TimeInterval = 35 * 24 * 60 * 60
    static let minimumChunk: TimeInterval = 15 * 60

    static func windowStart(now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
    }

    /// One range for this refresh. A pending retry wins. Once every day before today is covered, the
    /// range is the last cached event minus six hours. Otherwise it is the newest missing piece of a
    /// single calendar day. The open tail of today — the gap after the last successful fetch, created
    /// only because `now` moved — is not a hole, or backfill would never reach yesterday.
    static func nextRange(
        snapshot: CursorSpendCacheSnapshot,
        now: Date,
        calendar: Calendar
    ) -> CursorSpendInterval {
        if let retry = preferredRetry(snapshot.retry, now: now) {
            return retry
        }
        let startOfToday = calendar.startOfDay(for: now)
        let window = windowStart(now: now, calendar: calendar)
        if covers(snapshot.covered, from: window, to: startOfToday) {
            return incrementalRange(snapshot: snapshot, windowStart: window, now: now)
        }
        for offset in 0...29 {
            let dayStart = calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
            let dayEnd = offset == 0
                ? now
                : (calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
            guard dayEnd > dayStart else { continue }
            var gaps = uncoveredSegments(snapshot.covered, from: dayStart, to: dayEnd)
            if offset == 0 {
                gaps.removeAll { isLiveTail($0, covered: snapshot.covered, todayStart: dayStart) }
            }
            if let newest = gaps.last {
                return newest
            }
        }
        return incrementalRange(snapshot: snapshot, windowStart: window, now: now)
    }

    /// The later half of `range`, unless it is already at the minimum chunk.
    static func halvedRetry(_ range: CursorSpendInterval) -> CursorSpendInterval {
        let span = range.end.timeIntervalSince(range.start)
        guard span > minimumChunk else { return range }
        return CursorSpendInterval(start: range.end.addingTimeInterval(-span / 2), end: range.end)
    }

    /// A body that rejected at least one row and does not end on a record boundary. A complete file
    /// with an isolated bad row still ends in a newline and is safe to merge.
    static func bodyIsTruncated(_ csv: String, rejectedRowCount: Int) -> Bool {
        guard rejectedRowCount > 0 else { return false }
        return !csv.hasSuffix("\n") && !csv.hasSuffix("\r")
    }

    /// Replace rows inside `range` when the response has any, and record the range as covered either
    /// way. A zero-row body therefore does not punch a hole in the overlap. Rows older than the
    /// retention window are dropped.
    static func merge(
        _ snapshot: CursorSpendCacheSnapshot,
        range: CursorSpendInterval,
        rows incoming: [CursorUsageCSVRow],
        now: Date
    ) -> CursorSpendCacheSnapshot {
        var next = snapshot
        let accepted = incoming.filter { contains($0.date, range: range, now: now) }
        if !accepted.isEmpty {
            next.rows.removeAll { contains($0.date, range: range, now: now) }
            next.rows.append(contentsOf: accepted.map { row in
                CursorSpendCachedRow(
                    date: row.date,
                    model: row.model,
                    input: row.tokens.input,
                    cacheWrite5m: row.tokens.cacheWrite5m,
                    cacheRead: row.tokens.cacheRead,
                    output: row.tokens.output
                )
            })
        }
        next.covered.append(range)
        next.covered = merged(next.covered)
        next.retry = nil
        let cutoff = now.addingTimeInterval(-retention)
        next.rows.removeAll { $0.date < cutoff }
        next.covered = merged(next.covered).compactMap { interval in
            guard interval.end > cutoff else { return nil }
            var clipped = interval
            if clipped.start < cutoff { clipped.start = cutoff }
            return clipped.end > clipped.start ? clipped : nil
        }
        next.rows.sort { $0.date < $1.date }
        return next
    }

    static func pricedRows(_ rows: [CursorSpendCachedRow], pricing: ModelPricing) -> [CursorUsageCSVRow] {
        rows.map { row in
            let tokens = row.tokens
            return CursorUsageCSVRow(
                date: row.date,
                model: row.model,
                tokens: tokens,
                imputedCostDollars: pricing.estimatedCostDollars(
                    model: row.model,
                    tokens: tokens,
                    applyLongContextRates: false
                )
            )
        }
    }

    private static func preferredRetry(_ retry: CursorSpendInterval?, now: Date) -> CursorSpendInterval? {
        guard let retry, retry.end > retry.start, retry.end <= now.addingTimeInterval(1) else { return nil }
        let end = min(retry.end, now)
        guard end > retry.start else { return nil }
        return CursorSpendInterval(start: retry.start, end: end)
    }

    private static func incrementalRange(
        snapshot: CursorSpendCacheSnapshot,
        windowStart: Date,
        now: Date
    ) -> CursorSpendInterval {
        let anchor = snapshot.rows.map(\.date).max() ?? now
        let start = min(max(windowStart, anchor.addingTimeInterval(-overlap)), now)
        return CursorSpendInterval(start: start, end: now)
    }

    private static func contains(_ date: Date, range: CursorSpendInterval, now: Date) -> Bool {
        guard date >= range.start else { return false }
        if range.end == now { return date <= range.end }
        return date < range.end
    }

    private static func isLiveTail(
        _ gap: CursorSpendInterval,
        covered: [CursorSpendInterval],
        todayStart: Date
    ) -> Bool {
        guard gap.start > todayStart else { return false }
        return merged(covered).contains { $0.end == gap.start }
    }

    private static func covers(_ covered: [CursorSpendInterval], from start: Date, to end: Date) -> Bool {
        guard end > start else { return true }
        return uncoveredSegments(covered, from: start, to: end).isEmpty
    }

    private static func uncoveredSegments(
        _ covered: [CursorSpendInterval],
        from start: Date,
        to end: Date
    ) -> [CursorSpendInterval] {
        guard end > start else { return [] }
        var cursor = start
        var gaps: [CursorSpendInterval] = []
        for interval in merged(covered) {
            if interval.end <= cursor { continue }
            if interval.start >= end { break }
            if interval.start > cursor {
                let gapEnd = min(interval.start, end)
                if gapEnd > cursor {
                    gaps.append(CursorSpendInterval(start: cursor, end: gapEnd))
                }
            }
            cursor = max(cursor, interval.end)
            if cursor >= end { break }
        }
        if cursor < end {
            gaps.append(CursorSpendInterval(start: cursor, end: end))
        }
        return gaps
    }

    private static func merged(_ intervals: [CursorSpendInterval]) -> [CursorSpendInterval] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [CursorSpendInterval] = []
        for interval in sorted {
            if var last = result.last, interval.start <= last.end {
                last.end = max(last.end, interval.end)
                result[result.count - 1] = last
            } else {
                result.append(interval)
            }
        }
        return result
    }
}

struct CursorSpendCacheStore: Sendable {
    let directory: URL

    static var live: CursorSpendCacheStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return CursorSpendCacheStore(
            directory: base.appendingPathComponent("OpenUsage/cursor-spend-cache", isDirectory: true)
        )
    }

    func load(userID: String) -> CursorSpendCacheSnapshot {
        guard let data = try? Data(contentsOf: fileURL(for: userID)),
              let envelope = try? Self.makeDecoder().decode(CursorSpendCacheEnvelope.self, from: data),
              envelope.formatVersion == CursorSpendCacheEnvelope.formatVersion,
              envelope.userID == userID
        else {
            return .empty
        }
        return envelope.snapshot
    }

    func save(userID: String, _ snapshot: CursorSpendCacheSnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try Self.makeEncoder().encode(
                CursorSpendCacheEnvelope(formatVersion: CursorSpendCacheEnvelope.formatVersion, userID: userID, snapshot: snapshot)
            )
            let url = fileURL(for: userID)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "could not save the usage CSV cache")
        }
    }

    private func fileURL(for userID: String) -> URL {
        directory.appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(userID)).json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct CursorSpendCacheEnvelope: Codable {
    static let formatVersion = 1

    var formatVersion: Int
    var userID: String
    var snapshot: CursorSpendCacheSnapshot
}
