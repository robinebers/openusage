import Foundation

/// One API-meter observation for a bounded quota. Persisted locally; never copied into iCloud history.
struct QuotaSample: Codable, Equatable, Sendable {
    var recordedAt: Date
    var used: Double
    var limit: Double
    var resetsAt: Date
    var periodDuration: TimeInterval
}

/// One completed weekly-scale cycle, frozen when `resetsAt` advances. Tokens/cost are local-log
/// calendar days in the window — implied cap is `tokens / (endUsed/limit)`, noisy below ~20% used.
struct QuotaCycleRollup: Codable, Equatable, Sendable {
    static let maxStored = 26

    var resetsAt: Date
    var periodDuration: TimeInterval
    var endUsed: Double
    var limit: Double
    var plan: String?
    var tokens: Int
    var costUSD: Double?
    var closedAt: Date

    var impliedCapTokens: Double? {
        guard endUsed > 0, limit > 0 else { return nil }
        return Double(tokens) / (endUsed / limit)
    }

    var impliedCapUSD: Double? {
        guard let costUSD, endUsed > 0, limit > 0 else { return nil }
        return costUSD / (endUsed / limit)
    }
}

/// Mac-local ring of quota-percent samples keyed by account identity + metric.
/// Application Support only — not UserDefaults snapshots, not the iCloud spend document.
final class QuotaSampleStore: @unchecked Sendable {
    static let folderName = "quota-samples"
    static let fileName = "quota-samples-v1.json"

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/\(folderName)", isDirectory: true)
    }

    static var defaultFileURL: URL {
        defaultDirectory.appendingPathComponent(fileName)
    }

    private struct Payload: Codable {
        var rings: [String: [QuotaSample]]
        var cycles: [String: [QuotaCycleRollup]]?
    }

    private let lock = NSLock()
    private var rings: [String: [QuotaSample]] = [:]
    private var cycles: [String: [QuotaCycleRollup]] = [:]
    private var dirty = false
    private let fileURL: URL?
    private let fileManager: FileManager

    /// `fileURL == nil` keeps the ring in memory only (tests).
    init(fileURL: URL? = defaultFileURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if let fileURL {
            loadLocked(from: fileURL)
        }
    }

    static func key(identityKey: String, metricID: String) -> String {
        "\(identityKey)\u{1f}\(metricID)"
    }

    func record(
        identityKey: String,
        metricID: String,
        sample: QuotaSample,
        plan: String? = nil,
        daily: [DailyUsageEntry] = [],
        calendar: Calendar = .current
    ) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(identityKey: identityKey, metricID: metricID)
        var list = rings[key] ?? []
        if let last = list.last {
            // Close on a real window advance (hours), not 1–2s API jitter or a 2-minute
            // sliding weekly reset (Antigravity). Also close on a same-window used drop —
            // Anthropic wiped weekly 31%→2% on a new-model launch without moving resetsAt.
            if last.periodDuration >= Pace.weeklyScaleMinimum,
               Self.isCycleAdvance(from: last, to: sample) || Self.isUsageWipe(from: last, to: sample) {
                closeCycleLocked(key: key, last: last, plan: plan, daily: daily,
                                 calendar: calendar, closedAt: sample.recordedAt)
            }
            if last.limit > 0 {
                let jump = abs(sample.limit - last.limit) / last.limit
                if jump >= Pace.limitJumpWipeFraction {
                    list = []
                }
            }
        }
        if let last = list.last, Self.sameWindow(last, sample) {
            if last.used == sample.used, last.limit == sample.limit {
                rings[key] = list
                return
            }
            if Self.sameBucket(last, sample) {
                list[list.count - 1] = sample
                rings[key] = list
                dirty = true
                return
            }
        }
        list.append(sample)
        let cutoff = sample.recordedAt.addingTimeInterval(-35 * 86_400)
        list.removeAll { $0.recordedAt < cutoff }
        if list.count > Pace.maxSamplesPerMeter {
            list.removeFirst(list.count - Pace.maxSamplesPerMeter)
        }
        rings[key] = list
        dirty = true
    }

    /// Atomic write of the in-memory ring. Call once per refresh batch, not per meter.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty else { return }
        persistLocked()
        dirty = false
    }

    private static func sameWindow(_ a: QuotaSample, _ b: QuotaSample) -> Bool {
        abs(a.resetsAt.timeIntervalSince(b.resetsAt)) <= Pace.windowJitterTolerance
    }

    /// True when `sample` is a new weekly-scale cycle, not jitter or a slowly sliding reset.
    static func isCycleAdvance(from last: QuotaSample, to sample: QuotaSample) -> Bool {
        let delta = sample.resetsAt.timeIntervalSince(last.resetsAt)
        let minAdvance = max(Pace.windowJitterTolerance, last.periodDuration * 0.01)
        return delta > minAdvance
    }

    /// True when used fell hard without a calendar reset — vendor wiped the pool in place.
    static func isUsageWipe(from last: QuotaSample, to sample: QuotaSample) -> Bool {
        guard last.limit > 0 else { return false }
        if abs(sample.limit - last.limit) / last.limit >= Pace.limitJumpWipeFraction { return false }
        if isCycleAdvance(from: last, to: sample) { return false }
        return (last.used - sample.used) >= Pace.usageWipeDrop(limit: last.limit)
    }

    private static func sameBucket(_ a: QuotaSample, _ b: QuotaSample) -> Bool {
        bucket(a) == bucket(b)
    }

    private static func bucket(_ sample: QuotaSample) -> Int {
        let period = sample.periodDuration > 0 ? sample.periodDuration : 1
        let start = sample.resetsAt.addingTimeInterval(-period)
        let elapsed = max(0, sample.recordedAt.timeIntervalSince(start))
        let width = period >= Pace.weeklyScaleMinimum ? Pace.weeklySampleBucket : Pace.sessionSampleBucket
        return Int(elapsed / width)
    }

    func samples(identityKey: String, metricID: String) -> [QuotaSample] {
        lock.lock()
        defer { lock.unlock() }
        return rings[Self.key(identityKey: identityKey, metricID: metricID)] ?? []
    }

    func cycles(identityKey: String, metricID: String) -> [QuotaCycleRollup] {
        lock.lock()
        defer { lock.unlock() }
        return cycles[Self.key(identityKey: identityKey, metricID: metricID)] ?? []
    }

    static func dayKeys(windowStart: Date, resetsAt: Date, calendar: Calendar) -> [String] {
        var day = calendar.startOfDay(for: windowStart)
        let endDay = calendar.startOfDay(for: resetsAt)
        var keys: [String] = []
        while day < endDay {
            keys.append(DailyUsageAccumulator.dayKey(from: day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    private func closeCycleLocked(
        key: String,
        last: QuotaSample,
        plan: String?,
        daily: [DailyUsageEntry],
        calendar: Calendar,
        closedAt: Date
    ) {
        let existing = cycles[key] ?? []
        // Jitter can close twice with the same resetsAt and similar endUsed. A later wipe
        // (31 vs a fake 23) or the real Monday close after a mid-week wipe (71 vs 31)
        // must still record — same resetsAt, different endUsed.
        if existing.contains(where: {
            abs($0.resetsAt.timeIntervalSince(last.resetsAt)) <= Pace.windowJitterTolerance
                && abs($0.endUsed - last.used) < Pace.usageWipeDrop(limit: last.limit)
        }) { return }
        let start = last.resetsAt.addingTimeInterval(-last.periodDuration)
        let keys = Set(Self.dayKeys(windowStart: start, resetsAt: last.resetsAt, calendar: calendar))
        var tokens = 0
        var cost: Double = 0
        var hasCost = false
        for entry in daily where keys.contains(entry.date) {
            tokens += entry.totalTokens
            if let c = entry.costUSD {
                cost += c
                hasCost = true
            }
        }
        var list = existing
        list.append(QuotaCycleRollup(
            resetsAt: last.resetsAt,
            periodDuration: last.periodDuration,
            endUsed: last.used,
            limit: last.limit,
            plan: plan,
            tokens: tokens,
            costUSD: hasCost ? cost : nil,
            closedAt: closedAt
        ))
        if list.count > QuotaCycleRollup.maxStored {
            list.removeFirst(list.count - QuotaCycleRollup.maxStored)
        }
        cycles[key] = list
        dirty = true
    }

    func remainders(
        identityKey: String,
        metricID: String,
        now: Date,
        currentResetsAt: Date,
        currentPeriod: TimeInterval,
        calendar: Calendar = .current
    ) -> [Double] {
        Self.remainders(
            from: samples(identityKey: identityKey, metricID: metricID),
            now: now,
            currentResetsAt: currentResetsAt,
            currentPeriod: currentPeriod,
            calendar: calendar
        )
    }

    /// Remaining-at-this-slot over completed windows. Weekly-scale: weekday×hour. Session-scale:
    /// same window-start hour and elapsed 10-minute bucket. Most recent `Pace.historyK` values.
    static func remainders(
        from samples: [QuotaSample],
        now: Date,
        currentResetsAt: Date,
        currentPeriod: TimeInterval,
        calendar: Calendar
    ) -> [Double] {
        let completed = clusteredWindows(samples).filter { cluster in
            guard let canonical = cluster.first else { return false }
            let sameAsCurrent = abs(canonical.resetsAt.timeIntervalSince(currentResetsAt))
                <= Pace.windowJitterTolerance
            return !sameAsCurrent && canonical.resetsAt <= now
        }
        let currentStart = currentResetsAt.addingTimeInterval(-currentPeriod)
        let currentElapsed = now.timeIntervalSince(currentStart)
        let sessionScale = currentPeriod < Pace.weeklyScaleMinimum
        var collected: [Double] = []
        for window in completed.reversed() {
            guard let canonical = window.first,
                  let last = window.max(by: { $0.recordedAt < $1.recordedAt })
            else { continue }
            let period = last.periodDuration > 0 ? last.periodDuration : currentPeriod
            let start = canonical.resetsAt.addingTimeInterval(-period)
            if sessionScale {
                let currentStartHour = calendar.component(.hour, from: currentStart)
                let windowStartHour = calendar.component(.hour, from: start)
                guard windowStartHour == currentStartHour else { continue }
            }
            // Elapsed vs this sample's own reset clock, so ms jitter on resetsAt doesn't drop the
            // slot reading (canonical start can sit 0.09s before the slot sample).
            let atSlot = window
                .filter { sample in
                    let sampleStart = sample.resetsAt.addingTimeInterval(-period)
                    let sampleElapsed = sample.recordedAt.timeIntervalSince(sampleStart)
                    return sampleElapsed <= currentElapsed + Pace.windowJitterTolerance
                }
                .max(by: { $0.recordedAt < $1.recordedAt })
            guard let atSlot else { continue }
            collected.append(max(0, last.used - atSlot.used))
            if collected.count >= Pace.historyK { break }
        }
        return collected.reversed()
    }

    /// Samples whose `resetsAt` differ by at most `resetWindowJitterTolerance` belong to one cycle.
    /// Exact Date equality would split a week into one-sample fragments (remainder 0) and, once K≥2,
    /// replace linear with `used+0`.
    static func clusteredWindows(_ samples: [QuotaSample]) -> [[QuotaSample]] {
        let sorted = samples.sorted { $0.resetsAt < $1.resetsAt }
        var clusters: [[QuotaSample]] = []
        for sample in sorted {
            if let canonical = clusters.last?.first,
               abs(sample.resetsAt.timeIntervalSince(canonical.resetsAt))
                <= Pace.windowJitterTolerance {
                clusters[clusters.count - 1].append(sample)
            } else {
                clusters.append([sample])
            }
        }
        return clusters
    }

    private func loadLocked(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        rings = payload.rings
        cycles = payload.cycles ?? [:]
    }

    private func persistLocked() {
        guard let fileURL else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Payload(rings: rings, cycles: cycles))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.warn(.cache, "quota sample ring write failed: \(error.localizedDescription)")
        }
    }
}
