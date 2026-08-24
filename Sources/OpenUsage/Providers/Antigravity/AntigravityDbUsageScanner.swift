import Foundation

/// Reads token accounting from Antigravity's local conversation databases, discovered by FelixIsaac
/// in openusage#1058/#1120. Transcript JSONL files contain no usable generation token counts.
///
/// SQLite batches are bounded, and oversized protobufs are skipped before `hex(data)` runs: real
/// Antigravity sessions can contain generation blobs hundreds of megabytes in size.
struct AntigravityDbUsageScanner: Sendable {
    static let maximumBlobBytes = 1_048_576
    static let batchSize = 8

    var sqlite: SQLiteAccessing
    var conversationsDirectory: @Sendable () -> String

    private let readFailureReporter: UsageLogReadFailureReporter
    private let oversizedBlobReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        conversationsDirectory: @escaping @Sendable () -> String = AntigravityDbUsageScanner.defaultConversationsDirectory,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        oversizedBlobWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.conversationsDirectory = conversationsDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: readFailureWarning
        )
        self.oversizedBlobReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: oversizedBlobWarning ?? { count in
                let noun = count == 1 ? "database" : "databases"
                AppLog.warn(LogTag.plugin("antigravity"), "Skipped oversized generation records in \(count) Antigravity \(noun)")
            }
        )
    }

    static let defaultConversationsDirectory: @Sendable () -> String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversations").path
    }

    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directory = expandHome(conversationsDirectory())
        let paths: [String]
        do {
            paths = try Self.databaseFiles(in: directory)
        } catch {
            let newlyFailing = await readFailureReporter.update(checkedPaths: [directory], failingPaths: [directory])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("antigravity"), "conversation directory unreadable: \(error.localizedDescription)")
            }
            return nil
        }

        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [directory], failingPaths: [])
            return nil
        }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var accumulator = DailyUsageAccumulator()
        var failingPaths: [String: String] = [:]
        var oversizedPaths: Set<String> = []

        for path in paths {
            guard !Task.isCancelled else { return nil }
            do {
                if try readDatabase(path: path, since: since, pricing: pricing, into: &accumulator) {
                    oversizedPaths.insert(path)
                }
            } catch {
                failingPaths[path] = error.localizedDescription
            }
        }

        let checkedPaths = Set(paths)
        let newlyFailing = await readFailureReporter.update(
            checkedPaths: checkedPaths,
            failingPaths: Set(failingPaths.keys)
        )
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "usage query failed for \(path): \(failingPaths[path] ?? "unknown error")")
        }

        let newlyOversized = await oversizedBlobReporter.update(
            checkedPaths: checkedPaths,
            failingPaths: oversizedPaths
        )
        for path in newlyOversized.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "generation records larger than \(Self.maximumBlobBytes) bytes skipped in \(path)")
        }

        let result = accumulator.build()
        return result.series.daily.isEmpty && result.unknownModelsByDay.isEmpty ? nil : result
    }

    /// `CASE` prevents SQLite from expanding oversized blobs, while the inner `LIMIT` bounds the
    /// maximum hex payload returned by any subprocess to roughly `batchSize * maximumBlobBytes * 2`.
    static func dataSQL(after index: Int) -> String {
        """
        SELECT json_group_array(json_array(idx,
            CASE WHEN length(data) <= \(maximumBlobBytes) THEN hex(data) ELSE NULL END))
        FROM (
            SELECT idx, data FROM gen_metadata
            WHERE idx > \(index)
            ORDER BY idx
            LIMIT \(batchSize)
        )
        """
    }

    @discardableResult
    private func readDatabase(
        path: String,
        since: Date,
        pricing: ModelPricing,
        into accumulator: inout DailyUsageAccumulator
    ) throws -> Bool {
        var lastIndex = -1
        var sawOversizedBlob = false

        while !Task.isCancelled {
            guard let payload = try sqlite.queryValue(path: path, sql: Self.dataSQL(after: lastIndex)) else { break }
            let rows = try Self.rows(from: payload)
            guard !rows.isEmpty else { break }

            for row in rows {
                guard row.index > lastIndex else {
                    throw SQLiteError.queryFailed("Antigravity generation indices are not strictly increasing")
                }
                lastIndex = row.index

                guard let hex = row.hex else {
                    sawOversizedBlob = true
                    continue
                }
                Self.accumulate(hex, since: since, pricing: pricing, into: &accumulator)
            }

            if rows.count < Self.batchSize { break }
        }

        return sawOversizedBlob
    }

    private struct Row {
        var index: Int
        var hex: String?
    }

    private static func rows(from payload: String) throws -> [Row] {
        guard let data = payload.data(using: .utf8),
              let entries = try JSONSerialization.jsonObject(with: data) as? [[Any]]
        else {
            throw SQLiteError.queryFailed("Antigravity generation query returned malformed JSON")
        }

        return try entries.map { entry in
            guard entry.count == 2,
                  let indexNumber = entry[0] as? NSNumber,
                  let index = Int(exactly: indexNumber.int64Value)
            else {
                throw SQLiteError.queryFailed("Antigravity generation query returned a malformed row")
            }

            if entry[1] is NSNull {
                return Row(index: index, hex: nil)
            }
            guard let hex = entry[1] as? String else {
                throw SQLiteError.queryFailed("Antigravity generation query returned a malformed protobuf")
            }
            return Row(index: index, hex: hex)
        }
    }

    private static func accumulate(
        _ hex: String,
        since: Date,
        pricing: ModelPricing,
        into accumulator: inout DailyUsageAccumulator
    ) {
        guard let blob = bytes(fromHex: hex),
              let event = AntigravityProtoDecoder.generationEvent(from: blob)
        else { return }

        let date = Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds))
        guard date >= since else { return }

        let inputAndCached = event.inputTokens.addingReportingOverflow(event.cacheReadTokens)
        let total = inputAndCached.partialValue.addingReportingOverflow(event.outputTokens)
        guard !inputAndCached.overflow, !total.overflow, total.partialValue > 0 else { return }

        let day = DailyUsageAccumulator.dayKey(from: date)
        let tokens = TokenBreakdown(
            input: event.inputTokens,
            cacheRead: event.cacheReadTokens,
            output: event.outputTokens
        )

        guard let cost = pricing.estimatedCostDollars(model: event.model, tokens: tokens) else {
            accumulator.addUnknownModel(day: day, model: event.model)
            return
        }
        accumulator.add(day: day, tokens: total.partialValue, cost: cost, model: event.model)
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func databaseFiles(in directory: String) throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }

        return names
            .filter { $0.hasSuffix(".db") }
            .sorted()
            .map { directory.trimmingTrailingSlashes + "/" + $0 }
    }
}
