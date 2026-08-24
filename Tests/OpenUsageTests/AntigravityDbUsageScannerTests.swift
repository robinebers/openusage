import XCTest
@testable import OpenUsage

/// Synthetic protobuf fixtures follow FelixIsaac's original regression coverage in openusage#1058.
private func antigravityVarint(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var encoded: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        encoded.append(byte)
    } while remaining != 0
    return encoded
}

private func antigravityVarintField(_ number: UInt32, _ value: UInt64) -> [UInt8] {
    antigravityVarint(UInt64(number) << 3) + antigravityVarint(value)
}

private func antigravityBytesField(_ number: UInt32, _ bytes: [UInt8]) -> [UInt8] {
    antigravityVarint(UInt64(number) << 3 | 2) + antigravityVarint(UInt64(bytes.count)) + bytes
}

private func antigravityGenerationBlob(
    model: String?,
    input: UInt64,
    output: UInt64,
    cacheRead: UInt64 = 0,
    systemPrompt: UInt64 = 0,
    timestamp: UInt64?
) -> [UInt8] {
    let usage = antigravityVarintField(1, systemPrompt)
        + antigravityVarintField(2, input)
        + antigravityVarintField(3, output)
        + antigravityVarintField(5, cacheRead)

    var event: [UInt8] = []
    if let model {
        event += antigravityBytesField(19, Array(model.utf8))
    }
    event += antigravityBytesField(4, usage)

    if let timestamp {
        let wallClock = antigravityVarintField(1, timestamp)
        event += antigravityBytesField(9, antigravityBytesField(4, wallClock))
    }
    return antigravityBytesField(1, event)
}

private struct AntigravityFixtureRow: Sendable {
    var index: Int
    var blob: [UInt8]?
}

private final class AntigravityFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var rowsByPath: [String: [AntigravityFixtureRow]]
    private var cursors: [Int] = []
    let failingPaths: Set<String>
    let cancellingPath: String?

    init(rowsByPath: [String: [AntigravityFixtureRow]] = [:], failingPaths: Set<String> = [], cancellingPath: String? = nil) {
        self.rowsByPath = rowsByPath
        self.failingPaths = failingPaths
        self.cancellingPath = cancellingPath
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        if failingPaths.contains(path) {
            throw SQLiteError.queryFailed("database locked")
        }
        if path == cancellingPath { withUnsafeCurrentTask { $0?.cancel() } }
        let marker = "WHERE idx > "
        guard let markerRange = sql.range(of: marker),
              let cursor = Int(sql[markerRange.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "")
        else {
            throw SQLiteError.queryFailed("missing batch cursor")
        }
        cursors.append(cursor)

        let rows: [[String: Any]] = rowsByPath[path, default: []]
            .filter { $0.index > cursor }
            .sorted { $0.index < $1.index }
            .prefix(AntigravityDbUsageScanner.batchSize)
            .map { row in
                let value: Any = row.blob.map { bytes in
                    bytes.map { String(format: "%02x", $0) }.joined()
                } ?? NSNull()
                return ["index": row.index, "hex": value]
            }

        let json = try JSONSerialization.data(withJSONObject: rows)
        return String(decoding: json, as: UTF8.self)
    }

    func append(_ row: AntigravityFixtureRow, to path: String) {
        lock.withLock { rowsByPath[path, default: []].append(row) }
    }

    var queriedCursors: [Int] {
        lock.withLock { cursors }
    }

    func execute(path: String, sql: String) throws {}
}

final class AntigravityProtoDecoderTests: XCTestCase {
    func testDecodeVarintsAndRejectMalformedValues() {
        XCTAssertEqual(AntigravityProtoDecoder.decodeVarint([0x05])?.value, 5)
        XCTAssertEqual(AntigravityProtoDecoder.decodeVarint([0xac, 0x02])?.value, 300)
        XCTAssertNil(AntigravityProtoDecoder.decodeVarint([0x80]))
        XCTAssertNil(AntigravityProtoDecoder.decodeVarint(Array(repeating: 0xff, count: 11)))
        XCTAssertNil(AntigravityProtoDecoder.decodeVarint(Array(repeating: 0xff, count: 9) + [0x02]))
    }

    func testMalformedLengthCannotOverflowOrTrap() {
        let validField = antigravityVarintField(1, 42)
        let oversizedLength = antigravityVarint(UInt64(2) << 3 | 2) + antigravityVarint(UInt64.max)
        let fields = validField + oversizedLength

        XCTAssertEqual(AntigravityProtoDecoder.varintField(1, in: fields), 42)
        XCTAssertNil(AntigravityProtoDecoder.bytesField(2, in: fields))
    }

    func testExtractsCompleteGenerationRecord() throws {
        let blob = antigravityGenerationBlob(
            model: "gemini-3.1-pro-low",
            input: 1_000,
            output: 200,
            cacheRead: 50,
            systemPrompt: 1_132,
            timestamp: 1_800_000_000
        )
        let event = try XCTUnwrap(AntigravityProtoDecoder.generationEvent(from: blob))

        XCTAssertEqual(event.model, "gemini-3.1-pro-low")
        XCTAssertEqual(event.inputTokens, 2_132)
        XCTAssertEqual(event.outputTokens, 200)
        XCTAssertEqual(event.cacheReadTokens, 50)
        XCTAssertEqual(event.timestampSeconds, 1_800_000_000)
    }

    func testRejectsMissingTimestampZeroUsageAndUnrepresentableCounts() {
        let missingTimestamp = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 1, output: 0, timestamp: nil)
        let zeroUsage = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 0, output: 0, timestamp: 1_800_000_000)
        let overflowingTokens = antigravityGenerationBlob(model: "gemini-3.6-flash", input: UInt64.max, output: 0, timestamp: 1_800_000_000)
        let overflowingSystemPrompt = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: UInt64(Int.max), output: 0,
            systemPrompt: 1, timestamp: 1_800_000_000
        )

        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: missingTimestamp))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: zeroUsage))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: overflowingTokens))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: overflowingSystemPrompt))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: [0xff, 0xff, 0xff]))
    }
}

final class AntigravityDbUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-27T12:00:00.000Z")!
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "gemini-3.6-flash": ModelRates(
                inputPerMillion: 1,
                outputPerMillion: 4,
                cacheWritePerMillion: 1,
                cacheReadPerMillion: 0.25
            )
        ]),
        secondary: PricingCatalog()
    )

    private func makeDatabaseDirectory(fileNames: [String] = ["conversation.db"]) throws -> (url: URL, paths: [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = try fileNames.map { name in
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return url.path
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, paths)
    }

    func testMissingDatabaseDirectoryReturnsNil() async {
        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(),
            conversationsDirectory: { "/nonexistent-\(UUID().uuidString)" }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(result)
    }

    func testAccumulatesGenerationTokensCacheReadsAndEstimatedCost() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000_000,
            output: 500_000,
            cacheRead: 200_000,
            systemPrompt: 100_000,
            timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1_800_000)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 3.15, accuracy: 0.000_001)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, "gemini-3.6-flash")
    }

    func testScansMultipleBoundedBatches() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let rowCount = AntigravityDbUsageScanner.batchSize * 2 + 1
        let rows = (0..<rowCount).map { AntigravityFixtureRow(index: $0 * 2, blob: blob) }
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: rows])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, rowCount * 15)
    }

    func testReusesHistoryAndReadsOnlyRowsAddedToDatabaseOrWAL() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let first = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let second = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 20, output: 10, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: first)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        _ = await scanner.scan(now: now, pricing: pricing)
        _ = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(sqlite.queriedCursors, [-1])

        sqlite.append(.init(index: 1, blob: second), to: fixture.paths[0])
        try Data([1]).write(to: URL(fileURLWithPath: fixture.paths[0]))
        let updated = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(updated).series.daily.first?.totalTokens, 45)
        XCTAssertEqual(sqlite.queriedCursors, [-1, 0])

        sqlite.append(.init(index: 2, blob: first), to: fixture.paths[0])
        try Data([1]).write(to: URL(fileURLWithPath: fixture.paths[0] + "-wal"))
        let walUpdated = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(walUpdated).series.daily.first?.totalTokens, 60)
        XCTAssertEqual(sqlite.queriedCursors, [-1, 0, 1])
    }

    func testEvictsConversationHistoryAfterDatabaseAgesOutOfScanWindow() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let original = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: original)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        _ = await scanner.scan(now: now, pricing: pricing)
        let future = now.addingTimeInterval(31 * 86_400)
        let expired = await scanner.scan(now: future, pricing: pricing)
        XCTAssertNil(expired)

        let recent = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5,
            timestamp: UInt64(future.timeIntervalSince1970) - 3_600
        )
        sqlite.append(.init(index: 1, blob: recent), to: fixture.paths[0])
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fixture.paths[0])
        let refreshed = await scanner.scan(now: future, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(refreshed).series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedCursors, [-1, -1])
    }

    func testUnpricedAndMissingModelsRemainVisibleAsUnknown() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let unknown = antigravityGenerationBlob(model: "gemini-9-mystery", input: 100, output: 50, timestamp: timestamp)
        let missing = antigravityGenerationBlob(model: nil, input: 100, output: 50, timestamp: timestamp)
        let expired = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 100, output: 50,
            timestamp: UInt64(now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970)
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: unknown),
            .init(index: 1, blob: missing),
            .init(index: 2, blob: expired)
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(
            Set(scan.unknownModelsByDay.values.flatMap { $0 }),
            ["gemini-9-mystery", AntigravityProtoDecoder.GenerationEvent.unknownModel]
        )
    }

    func testOversizedBlobsAreSkippedAndWarnOnlyOnce() async throws {
        let fixture = try makeDatabaseDirectory()
        let recorder = Counter()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let valid = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: nil),
            .init(index: 1, blob: valid)
        ]])
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { fixture.url.path },
            oversizedBlobWarning: { _ in _ = recorder.next() }
        )

        let firstResult = await scanner.scan(now: now, pricing: pricing)
        let secondResult = await scanner.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(first.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(second.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(recorder.next(), 1)
    }

    func testUnreadableOrCancelledDatabaseCannotPublishPartialHistory() async throws {
        let fixture = try makeDatabaseDirectory(fileNames: ["a.db", "b.db"])
        let recorder = Counter()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[1]: [.init(index: 0, blob: blob)]],
            failingPaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { fixture.url.path },
            readFailureWarning: { _ in _ = recorder.next() }
        )

        let firstResult = await scanner.scan(now: now, pricing: pricing)
        let secondResult = await scanner.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(first.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(second.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(recorder.next(), 1)

        let cancellableSQLite = AntigravityFakeSQLite(
            rowsByPath: fixture.paths.reduce(into: [:]) { $0[$1] = [.init(index: 0, blob: blob)] },
            cancellingPath: fixture.paths[1]
        )
        let cancellableScanner = AntigravityDbUsageScanner(
            sqlite: cancellableSQLite, conversationsDirectory: { fixture.url.path }
        )
        let (fixedNow, fixedPricing) = (now, pricing)
        let cancelled = await Task { await cancellableScanner.scan(now: fixedNow, pricing: fixedPricing) }.value
        XCTAssertNil(cancelled)
    }

    func testBatchSQLBoundsRowsAndSkipsOversizedBlobsBeforeHexExpansion() {
        let sql = AntigravityDbUsageScanner.dataSQL(after: 42)

        XCTAssertTrue(sql.contains("WHERE idx > 42 AND data IS NOT NULL"))
        XCTAssertTrue(sql.contains("LIMIT \(AntigravityDbUsageScanner.batchSize)"))
        XCTAssertTrue(sql.contains("length(data) <= \(AntigravityDbUsageScanner.maximumBlobBytes)"))
        XCTAssertTrue(sql.contains("THEN hex(data) ELSE NULL"))
    }

    @MainActor
    func testProviderAddsConversationSpendToHistoryAndTotalSpend() async throws {
        let fixture = try makeDatabaseDirectory()
        let fixedNow = now
        let fixedPricing = pricing
        let timestamp = UInt64(fixedNow.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000_000,
            output: 500_000,
            timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let routing = RoutingHTTPClient { request in
            if request.url.path.contains("retrieveUserQuotaSummary") {
                let response = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(response.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let credentials = #"{"token":{"access_token":"ya29.test","refresh_token":"1//test","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrappedCredentials = "go-keyring-base64:" + Data(credentials.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrappedCredentials), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: scanner,
            now: { fixedNow },
            pricing: { fixedPricing }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Today", "Last 30 Days", "Usage Trend"])
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 1_500_000)

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [provider.provider],
            snapshots: [provider.provider.id: snapshot]
        )
        XCTAssertEqual(total.slices.map(\.provider.id), ["antigravity"])
        XCTAssertEqual(total.totalUSD, 3, accuracy: 0.000_001)
        XCTAssertEqual(total.totalTokens, 1_500_000)
        XCTAssertTrue(total.isEstimated)
    }
}
