import Foundation

/// The result of a local OpenCode scan: every provider's daily session usage (for the spend tiles +
/// trend) and the Go-only plan windows (for the meters). `goWindows` is nil without a current Go signal.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
    var goWindows: OpenCodeGoWindows?
    var warning: String?
}

/// Orchestrates OpenCode usage accounting from normalized database rows. SQLite/schema concerns live
/// in `OpenCodeUsageDatabaseReader`; recorded-versus-estimated cost decisions and model resolution live
/// in `OpenCodeCostEstimator`.
struct OpenCodeUsageScanner: Sendable {
    private let databaseReader: OpenCodeUsageDatabaseReader
    private let costEstimator: any OpenCodeCostEstimating
    private let invalidCostReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageDatabaseReader.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        costEstimator: any OpenCodeCostEstimating = OpenCodeCostEstimator()
    ) {
        self.databaseReader = OpenCodeUsageDatabaseReader(
            sqlite: sqlite,
            databasePaths: databasePaths,
            readFailureWarning: readFailureWarning
        )
        self.costEstimator = costEstimator
        self.invalidCostReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: { _ in
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "Found completed OpenCode usage with invalid cost data; excluding affected usage"
                )
            }
        )
    }

    /// Scan the last `daysBack` days. Thirty-three days covers the widest Go meter window plus slack;
    /// spend tiles and trends are bounded to 31 calendar days below.
    func scan(
        now: Date,
        daysBack: Int = 33,
        hasGoKey: Bool = false,
        pricing: ModelPricing = .empty
    ) async throws -> OpenCodeUsageScan? {
        try await scan(now: now, daysBack: daysBack, hasGoKey: hasGoKey, pricing: { pricing })
    }

    /// Loads shared pricing only when an external row actually needs estimation. Database discovery,
    /// hosted-only scans, and recorded external costs remain local and deterministic.
    func scan(
        now: Date,
        daysBack: Int = 33,
        hasGoKey: Bool = false,
        pricing: @Sendable () async -> ModelPricing
    ) async throws -> OpenCodeUsageScan? {
        guard let database = try await databaseReader.load(now: now, daysBack: daysBack) else {
            return nil
        }
        let rows = database.rows
        let tileSince = JSONLScanning.sinceDate(daysBack: 30, now: now)
        let invalidCostRows = rows.filter(Self.hasInvalidCost)
        let needsPricing = rows.contains { row in
            Date(timeIntervalSince1970: row.ms / 1000) >= tileSince
                && !OpenCodeProviderIDs.hosted.contains(row.providerID)
                && !row.hasInvalidRecordedCost
                && (row.recordedCost ?? 0) <= 0
                && row.bucketTokens > 0
                && row.tokens > 0
        }
        let resolvedPricing = needsPricing ? await pricing() : .empty

        // A malformed recorded cost is not legitimate free usage. Exclude the affected row, surface a
        // soft warning, and suppress Go meters only when the malformed accounting belongs to an active
        // Go window. Older malformed rows cannot make otherwise valid current meters disappear.
        let invalidVisibleCost = invalidCostRows.contains {
            Date(timeIntervalSince1970: $0.ms / 1000) >= tileSince
        }
        let invalidGoWindowCost = invalidCostRows.contains {
            $0.providerID == OpenCodeProviderIDs.go
                && OpenCodeGoWindowMath.containsActiveWindow(
                    timestampMs: $0.ms,
                    anchorMs: database.goAnchorMs,
                    now: now
                )
        }
        let invalidCostMarker = "<invalid cost>"
        await invalidCostReporter.update(
            checkedPaths: [invalidCostMarker],
            failingPaths: invalidCostRows.isEmpty ? [] : [invalidCostMarker]
        )

        var accumulator = DailyUsageAccumulator()
        var unpriceableModels: Set<String> = []
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)

            switch costEstimator.resolve(row: row, pricing: resolvedPricing) {
            case .priced(let tokens, let cost, let model):
                accumulator.add(day: day, tokens: tokens, cost: cost, model: model)
            case .unpriced(let model):
                accumulator.addUnknownModel(day: day, model: model)
                if !Self.hasInvalidCost(row) {
                    unpriceableModels.insert(model)
                }
            case .ignored:
                break
            }
        }
        let logScan = accumulator.build()
        var warnings: [String] = []
        if invalidGoWindowCost {
            warnings.append("Some completed OpenCode messages have invalid cost data. Affected usage and Go meters are unavailable.")
        } else if invalidVisibleCost {
            warnings.append("Some completed OpenCode messages have invalid cost data. Affected usage is excluded from totals.")
        }
        if logScan.series.daily.isEmpty, !unpriceableModels.isEmpty {
            warnings.append("OpenCode couldn't price usage for: \(unpriceableModels.sorted().joined(separator: ", ")).")
        }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")

        // Go caps use only recorded opencode-go accounting. A stale historical anchor cannot resurrect
        // the plan; a current key or recent Go cost is required before the anchor defines the cycle.
        let goCosts = rows.compactMap { row -> (ms: Double, cost: Double)? in
            guard row.providerID == OpenCodeProviderIDs.go,
                  let cost = row.recordedCost
            else { return nil }
            return (ms: row.ms, cost: cost)
        }
        let goWindows: OpenCodeGoWindows? = !invalidGoWindowCost && (hasGoKey || !goCosts.isEmpty)
            ? OpenCodeGoWindowMath.compute(costs: goCosts, anchorMs: database.goAnchorMs, now: now)
            : nil

        return OpenCodeUsageScan(logScan: logScan, goWindows: goWindows, warning: warning)
    }

    /// Local-only first-run/new-provider probe. Database failures are handled by the reader so a real
    /// OpenCode footprint can still enable the provider and surface the error during refresh.
    func hasUsage() -> Bool {
        databaseReader.hasUsage()
    }

    private static func hasInvalidCost(_ row: OpenCodeUsageRow) -> Bool {
        guard row.tokens > 0 else { return false }
        return row.hasInvalidRecordedCost
            || (OpenCodeProviderIDs.hosted.contains(row.providerID) && row.recordedCost == nil)
    }
}
