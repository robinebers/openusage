import Foundation

struct OpenCodeUsageRow: Sendable {
    var ms: Double
    var recordedCost: Double?
    var hasInvalidRecordedCost: Bool
    var tokens: Int
    var model: String
    var providerID: String
    var input: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
    var reasoning: Int
    var messageID: String?
    var hasExplicitCompletion: Bool

    var bucketTokens: Int {
        min(input + cacheRead + cacheWrite + output + reasoning, 1_000_000_000_000_000)
    }
}

struct OpenCodeUsageDatabaseSnapshot: Sendable {
    var rows: [OpenCodeUsageRow]
    var goAnchorMs: Double?
}

private enum OpenCodeUsageDatabaseReaderError: LocalizedError {
    case invalidAggregatePayload

    var errorDescription: String? {
        "OpenCode database returned malformed aggregate usage data."
    }
}

/// Owns OpenCode's SQLite boundary: database discovery, querying, row decoding, completion filtering,
/// and cross-channel deduplication. Higher layers receive normalized rows and do not depend on the
/// database schema or JSON layout.
struct OpenCodeUsageDatabaseReader: Sendable {
    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageDatabaseReader.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// Returns `nil` only when no OpenCode database exists. A present-but-empty database produces an
    /// empty snapshot, while an unreadable directory or an all-failed database set throws loudly.
    func load(now: Date, daysBack: Int) async throws -> OpenCodeUsageDatabaseSnapshot? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        let cutoffMs = Int((now.timeIntervalSince1970 - Double(daysBack) * 86_400) * 1000)
        var rows: [OpenCodeUsageRow] = []
        var anchorMs: Double?
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            checked.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: try Self.parseRows(json))
                }
            } catch {
                failures[path] = error.localizedDescription
                continue
            }
            // Monthly cycle anchor: the earliest-ever local Go usage (unbounded, so it survives the
            // day-window cutoff). Cheap and best-effort — a failure falls back to the calendar month.
            if let text = (try? sqlite.queryValue(path: path, sql: Self.anchorSQL)) ?? nil,
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                anchorMs = Swift.min(anchorMs ?? value, value)
            }
        }

        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // OpenCode may copy sessions between release-channel databases. Message IDs are stable, so
        // completed copies count once and the newest, most complete representation wins.
        rows = Self.deduplicated(rows.filter(\.hasExplicitCompletion))
        return OpenCodeUsageDatabaseSnapshot(rows: rows, goAnchorMs: anchorMs)
    }

    /// Cheap local probe for first-run and new-provider detection. An unreadable data directory counts
    /// as a footprint so the provider refresh can surface the actionable error.
    func hasUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        var failedProbeCount = 0
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL), !value.isEmpty {
                    return true
                }
            } catch {
                failedProbeCount += 1
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
            }
        }
        return !paths.isEmpty && failedProbeCount == paths.count
    }

    /// Parse the `json_group_array(json_array(...))` payload. Rows missing a timestamp or provider ID
    /// are rejected at this external-data boundary.
    private static func parseRows(_ json: String) throws -> [OpenCodeUsageRow] {
        guard let data = json.data(using: .utf8) else {
            throw OpenCodeUsageDatabaseReaderError.invalidAggregatePayload
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw OpenCodeUsageDatabaseReaderError.invalidAggregatePayload
        }

        var rows: [OpenCodeUsageRow] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 10,
                  let ms = ProviderParse.number(entry[0]),
                  let providerID = (entry[4] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty
            else { continue }

            let input = clampedTokens(entry[5])
            let cacheRead = clampedTokens(entry[6])
            let cacheWrite = clampedTokens(entry[7])
            let output = clampedTokens(entry[8])
            let reasoning = clampedTokens(entry[9])
            let bucketTotal = min(input + cacheRead + cacheWrite + output + reasoning, 1_000_000_000_000_000)
            let storedTotal = ProviderParse.number(entry[2]).map(clampedTokens) ?? 0
            let tokens = bucketTotal > 0 ? bucketTotal : storedTotal
            let rawRecordedCost = ProviderParse.number(entry[1])
            let hasInvalidRecordedCost = if entry[1] is NSNull {
                false
            } else if let rawRecordedCost {
                rawRecordedCost < 0
            } else {
                true
            }
            let recordedCost = rawRecordedCost.flatMap { $0 >= 0 ? $0 : nil }
            let model = ((entry[3] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let messageID = (entry.count > 10 ? entry[10] as? String : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let hasExplicitCompletion = entry.count <= 11 || (ProviderParse.number(entry[11]) ?? 0) > 0
            rows.append(OpenCodeUsageRow(
                ms: ms,
                recordedCost: recordedCost,
                hasInvalidRecordedCost: hasInvalidRecordedCost,
                tokens: tokens,
                model: model,
                providerID: providerID,
                input: input,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning,
                messageID: messageID,
                hasExplicitCompletion: hasExplicitCompletion
            ))
        }
        return rows
    }

    private static func clampedTokens(_ value: Any) -> Int {
        clampedTokens(ProviderParse.number(value) ?? 0)
    }

    private static func clampedTokens(_ value: Double) -> Int {
        Int(min(max(value, 0), 1_000_000_000_000_000))
    }

    private static func deduplicated(_ rows: [OpenCodeUsageRow]) -> [OpenCodeUsageRow] {
        var withoutID: [OpenCodeUsageRow] = []
        var byID: [String: OpenCodeUsageRow] = [:]
        for row in rows {
            guard let messageID = row.messageID else {
                withoutID.append(row)
                continue
            }
            guard let existing = byID[messageID] else {
                byID[messageID] = row
                continue
            }
            if rowIsPreferred(row, over: existing) {
                byID[messageID] = row
            }
        }
        return withoutID + byID.values
    }

    private static func rowIsPreferred(_ candidate: OpenCodeUsageRow, over existing: OpenCodeUsageRow) -> Bool {
        if candidate.ms != existing.ms { return candidate.ms > existing.ms }
        if (candidate.recordedCost != nil) != (existing.recordedCost != nil) {
            return candidate.recordedCost != nil
        }
        if candidate.bucketTokens != existing.bucketTokens {
            return candidate.bucketTokens > existing.bucketTokens
        }
        if candidate.tokens != existing.tokens { return candidate.tokens > existing.tokens }
        return (candidate.recordedCost ?? 0) > (existing.recordedCost ?? 0)
    }

    static func dataSQL(cutoffMs: Int) -> String {
        let creationCutoffMs = cutoffMs - 7 * 86_400_000
        return """
        SELECT json_group_array(json_array(
                 COALESCE(json_extract(data,'$.time.completed'),time_created),
                 json_extract(data,'$.cost'),
                 COALESCE(
                   json_extract(data,'$.tokens.total'),
                   COALESCE(json_extract(data,'$.tokens.input'),0)
                     + COALESCE(json_extract(data,'$.tokens.output'),0)
                     + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
                     + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                     + COALESCE(json_extract(data,'$.tokens.cache.write'),0)),
                 json_extract(data,'$.modelID'),
                 json_extract(data,'$.providerID'),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 id,
                 CASE WHEN json_type(data,'$.time.completed') IN ('integer','real')
                            OR json_type(data,'$.finish') = 'text'
                      THEN 1 ELSE 0 END))
        FROM message
        WHERE time_created >= \(creationCutoffMs)
          AND json_valid(data)
          AND COALESCE(json_extract(data,'$.time.completed'),time_created) >= \(cutoffMs)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_type(data,'$.providerID') = 'text'
          AND TRIM(json_extract(data,'$.providerID')) <> '';
        """
    }

    private static let anchorSQL = """
        SELECT MIN(time_created) FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = '\(OpenCodeProviderIDs.go)'
          AND json_type(data,'$.cost') IN ('integer','real')
          AND (json_type(data,'$.time.completed') IN ('integer','real')
               OR json_type(data,'$.finish') = 'text');
        """

    private static let probeSQL = """
        SELECT 1 FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_type(data,'$.providerID') = 'text'
          AND TRIM(json_extract(data,'$.providerID')) <> ''
        LIMIT 1;
        """
}
