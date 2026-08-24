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
    private let scanCache: AntigravityDbScanCache

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        conversationsDirectory: @escaping @Sendable () -> String = AntigravityDbUsageScanner.defaultConversationsDirectory,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        oversizedBlobWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.conversationsDirectory = conversationsDirectory
        self.scanCache = AntigravityDbScanCache()
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
        let checkedPaths = Set(paths)
        await scanCache.prune(keeping: checkedPaths, since: since)
        var accumulator = DailyUsageAccumulator()
        var failingPaths: [String: String] = [:]
        var oversizedPaths: Set<String> = []

        for path in paths {
            guard !Task.isCancelled else { return nil }
            do {
                let fingerprint = try AntigravityDbScanCache.Fingerprint(path: path)
                guard fingerprint.latestModification >= since else { continue }

                var cached = await scanCache.entry(for: path)
                if cached?.fingerprint != fingerprint || (cached?.windowStart ?? since) > since {
                    if cached?.fingerprint.databaseIdentifier != fingerprint.databaseIdentifier
                        || (cached?.fingerprint.databaseSize ?? 0) > fingerprint.databaseSize
                        || (cached?.windowStart ?? since) > since
                    {
                        cached = nil
                    }

                    let existingEvents = cached?.events.filter {
                        Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)) >= since
                    } ?? []
                    let update = try readDatabase(path: path, after: cached?.lastIndex ?? -1, since: since)
                    guard !Task.isCancelled else { return nil }
                    let refreshed = AntigravityDbScanCache.Entry(
                        fingerprint: fingerprint,
                        windowStart: since,
                        lastIndex: update.lastIndex ?? cached?.lastIndex ?? -1,
                        events: existingEvents + update.events,
                        sawOversizedBlob: (cached?.sawOversizedBlob ?? false) || update.sawOversizedBlob
                    )
                    cached = refreshed
                    await scanCache.store(refreshed, for: path)
                }

                guard let cached else { continue }
                for event in cached.events {
                    Self.accumulate(event, since: since, pricing: pricing, into: &accumulator)
                }
                if cached.sawOversizedBlob {
                    oversizedPaths.insert(path)
                }
            } catch {
                failingPaths[path] = error.localizedDescription
            }
        }

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

    private func readDatabase(
        path: String,
        after index: Int,
        since: Date
    ) throws -> (lastIndex: Int?, events: [AntigravityProtoDecoder.GenerationEvent], sawOversizedBlob: Bool) {
        var lastIndex = index
        var events: [AntigravityProtoDecoder.GenerationEvent] = []
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
                guard let blob = Self.bytes(fromHex: hex),
                      let event = AntigravityProtoDecoder.generationEvent(from: blob),
                      Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds)) >= since
                else { continue }
                events.append(event)
            }

            if rows.count < Self.batchSize { break }
        }

        return (lastIndex == index ? nil : lastIndex, events, sawOversizedBlob)
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
        _ event: AntigravityProtoDecoder.GenerationEvent,
        since: Date,
        pricing: ModelPricing,
        into accumulator: inout DailyUsageAccumulator
    ) {
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

private actor AntigravityDbScanCache {
    struct Fingerprint: Equatable, Sendable {
        let databaseIdentifier: UInt64
        let databaseSize: Int64
        let databaseModification: Date
        let walSize: Int64?
        let walModification: Date?

        init(path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            databaseIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            databaseSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            databaseModification = attributes[.modificationDate] as? Date ?? .distantPast

            do {
                let walAttributes = try FileManager.default.attributesOfItem(atPath: path + "-wal")
                walSize = (walAttributes[.size] as? NSNumber)?.int64Value ?? 0
                walModification = walAttributes[.modificationDate] as? Date ?? .distantPast
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                walSize = nil
                walModification = nil
            }
        }

        var latestModification: Date {
            max(databaseModification, walModification ?? .distantPast)
        }
    }

    struct Entry: Sendable {
        let fingerprint: Fingerprint
        let windowStart: Date
        let lastIndex: Int
        let events: [AntigravityProtoDecoder.GenerationEvent]
        let sawOversizedBlob: Bool
    }

    private var entries: [String: Entry] = [:]

    func entry(for path: String) -> Entry? { entries[path] }
    func store(_ entry: Entry, for path: String) { entries[path] = entry }
    func prune(keeping paths: Set<String>, since: Date) {
        entries = entries.filter {
            paths.contains($0.key) && $0.value.fingerprint.latestModification >= since
        }
    }
}
