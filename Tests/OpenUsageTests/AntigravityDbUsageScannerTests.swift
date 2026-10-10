import XCTest
@testable import OpenUsage

final class AntigravityDbUsageScannerTests: XCTestCase {
    private let now = antigravityNow
    private let pricing = antigravityPricing

    private func makeDatabaseDirectory(fileNames: [String] = ["conversation.db"]) throws -> (url: URL, paths: [String]) {
        try makeAntigravityDatabaseDirectory(for: self, fileNames: fileNames)
    }

    func testMissingDatabaseDirectoryReturnsNil() async {
        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(),
            conversationsDirectories: { ["/nonexistent-\(UUID().uuidString)"] }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(result)
    }

    func testPlaceholderFallsBackToThePricedIDWhenTheLabelIsUnpriced() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: antigravityGenerationBlob(
                model: "gemini-pro-default", input: 10, output: 5, label: "Gemini 9 Mystery (High)", timestamp: timestamp
            )),
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

        let result = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.map(\.model), ["gemini-3.1-pro"])
    }

    func testBreakdownRowsFoldEffortVariantsLabelsAndPlaceholdersIntoOneFamily() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: antigravityGenerationBlob(model: "gemini-3.1-pro-low", input: 10, output: 0, timestamp: timestamp)),
            .init(index: 1, blob: antigravityGenerationBlob(
                model: "gemini-pro-default", input: 5, output: 0, label: "Gemini 3.1 Pro (High)", timestamp: timestamp
            )),
            .init(index: 2, blob: antigravityGenerationBlob(model: "gemini-pro-agent", input: 1, output: 0, timestamp: timestamp)),
            .init(index: 3, blob: antigravityGenerationBlob(model: "gemini-3.7-flash-exp-a", input: 2, output: 0, timestamp: timestamp)),
            .init(index: 4, blob: antigravityGenerationBlob(model: "gemini-3.7-flash-tiered", input: 3, output: 0, timestamp: timestamp)),
            .init(index: 5, blob: antigravityGenerationBlob(model: "gemini-3.8-flash-n", input: 4, output: 0, timestamp: timestamp)),
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

        let result = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        // Breakdown rows carry no inherent order; the history aggregator sorts them for display.
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: models.map { ($0.model, $0.totalTokens) }),
            ["gemini-3.1-pro": 16, "gemini-3.7-flash": 5, "gemini-3.8-flash": 4]
        )
    }

    func testBookkeepingRowsDoNotRaiseTheUnknownModelWarning() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: antigravityGenerationBlob(model: nil, input: 0, output: 0, systemPrompt: 1_036, timestamp: timestamp)),
            .init(index: 1, blob: antigravityGenerationBlob(
                model: "gemini-default", input: 10, output: 5, label: "Gemini 3.6 Flash (High)", timestamp: timestamp
            )),
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

        // The bundled supplement carries the display-label alias rules under test.
        let result = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.map(\.model), ["gemini-3.6-flash"])
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
    }

    func testTieredSubagentModelsFoldIntoTheBaseModelRow() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 0, timestamp: timestamp)),
            .init(index: 1, blob: antigravityGenerationBlob(model: "gemini-3.6-flash-tiered", input: 5, output: 0, timestamp: timestamp)),
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(models.map(\.model), ["gemini-3.6-flash"])
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
    }

    func testScansEveryConversationDirectoryAndSkipsMissingOnes() async throws {
        let cli = try makeDatabaseDirectory()
        let ide = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [
            cli.paths[0]: [.init(index: 0, blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 0, timestamp: timestamp))],
            ide.paths[0]: [.init(index: 0, blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 5, output: 0, timestamp: timestamp))],
        ])
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectories: { [cli.url.path, "/nonexistent-\(UUID().uuidString)", ide.url.path] }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
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
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

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
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

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
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

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
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })
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
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(
            Set(scan.unknownModelsByDay.values.flatMap { $0 }),
            ["gemini-9-mystery", AntigravityDbUsageScanner.unknownModel]
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
            conversationsDirectories: { [fixture.url.path] },
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
            conversationsDirectories: { [fixture.url.path] },
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
            sqlite: cancellableSQLite, conversationsDirectories: { [fixture.url.path] }
        )
        let (fixedNow, fixedPricing) = (now, pricing)
        let cancelled = await Task { await cancellableScanner.scan(now: fixedNow, pricing: fixedPricing) }.value
        XCTAssertNil(cancelled)
    }

    func testBatchSQLBoundsRowsAndSkipsOversizedBlobsBeforeHexExpansion() {
        let sql = AntigravityDbUsageScanner.dataSQL(after: 42)

        let limit = AntigravityDbUsageScanner.maximumBlobBytes

        XCTAssertTrue(sql.contains("WHERE idx > 42 AND data IS NOT NULL"))
        XCTAssertTrue(sql.contains("LIMIT \(AntigravityDbUsageScanner.batchSize)"))
        XCTAssertTrue(sql.contains("length(g.data) <= \(limit)"))
        XCTAssertTrue(sql.contains("THEN hex(g.data) ELSE NULL"))
        XCTAssertTrue(sql.contains("length(metadata) <= \(limit) THEN hex(metadata) ELSE NULL END FROM steps WHERE idx = g.idx"))

        let legacySQL = AntigravityDbUsageScanner.dataSQL(after: 42, includeSteps: false)
        XCTAssertTrue(legacySQL.contains("THEN hex(g.data) ELSE NULL END))"))
        XCTAssertFalse(legacySQL.contains("steps"))
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
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectories: { [fixture.url.path] })

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
