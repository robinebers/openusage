import XCTest
@testable import OpenUsage

/// The Muse session-log scan: parse `model_completed` run events (bare and retained-frame
/// wrapped), skip mirrored subagent transcripts, and price through the shared engine.
final class MuseUsageScannerTests: XCTestCase {
    /// Fixture pricing with the published Muse Spark rates: Standard $1.25/M in, $4.25/M out,
    /// $0.15/M cache read; contributor $0.10/M in, $0.20/M out.
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "muse-spark-1.3": ModelRates(
                inputPerMillion: 1.25, outputPerMillion: 4.25,
                cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.15
            ),
            "muse-spark-1.3-contributor": ModelRates(
                inputPerMillion: 0.1, outputPerMillion: 0.2,
                cacheWritePerMillion: 0.1, cacheReadPerMillion: 0.01
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func micros(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }

    private func record(
        at date: Date = Date(timeIntervalSince1970: 1_788_631_200),
        model: String = "muse-spark-1.3",
        input: Int = 10_000, output: Int = 500,
        cached: Int = 8_000, cacheRead: Int? = nil, cacheWrite: Int = 0, reasoning: Int = 100
    ) -> Data {
        let read = cacheRead ?? cached
        let json = """
        {"schema_version":1,"id":"r1","stream":{"kind":"session","id":"s1"},"sequence":1,\
        "recorded_at":\(micros(date)),"record_type":"event","payload_type":"runtime.session",\
        "payload":{"kind":"run","event":{"kind":"model_completed",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cached_tokens":\(cached),\
        "cache_read_tokens":\(read),"cache_write_tokens":\(cacheWrite),\
        "reasoning_tokens":\(reasoning)},"duration_ms":100,"model":"\(model)"}}}
        """
        return Data(json.utf8)
    }

    private func wrapped(_ inner: Data) -> Data {
        let object: [String: Any] = [
            "retained_frame": "x", "frame_schema_version": 1,
            "children": [["child_index": 0, "record_json": String(decoding: inner, as: UTF8.self)]]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Parsing

    func testParsesModelCompletedBuckets() {
        let entry = MuseUsageScanner.recordEntry(record())
        XCTAssertEqual(entry?.model, "muse-spark-1.3")
        // Non-cached input prices at the input rate; reasoning folds into output (Meta bills it so).
        XCTAssertEqual(entry?.input, 2_000)
        XCTAssertEqual(entry?.cacheRead, 8_000)
        XCTAssertEqual(entry?.output, 600)
        XCTAssertEqual(entry?.reportedTotalTokens, 10_600)
        XCTAssertEqual(entry?.timestamp, Date(timeIntervalSince1970: 1_788_631_200))
    }

    func testFallsBackToCachedTokensWhenCacheReadAbsent() {
        var object = try! JSONSerialization.jsonObject(with: record()) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var event = payload["event"] as! [String: Any]
        var usage = event["usage"] as! [String: Any]
        usage.removeValue(forKey: "cache_read_tokens")
        event["usage"] = usage
        payload["event"] = event
        object["payload"] = payload
        let entry = MuseUsageScanner.recordEntry(try! JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(entry?.cacheRead, 8_000)
        XCTAssertEqual(entry?.input, 2_000)
    }

    func testIgnoresNonUsagePayloads() {
        let resource = Data(
            #"{"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"resource_usage_sampled","usage":{"rss_self_bytes":1}}}}"#.utf8
        )
        XCTAssertNil(MuseUsageScanner.recordEntry(resource))
        XCTAssertNil(MuseUsageScanner.recordEntry(Data("not json".utf8)))
        // Zero-usage completions carry nothing to count.
        XCTAssertNil(MuseUsageScanner.recordEntry(record(input: 0, output: 0, cached: 0, reasoning: 0)))
        // A step with no model can't be priced or labeled.
        XCTAssertNil(MuseUsageScanner.recordEntry(record(model: "  ")))
    }

    func testParsesRetainedFrameWrapper() {
        let entries = MuseUsageScanner.parseFile(wrapped(record()))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.model, "muse-spark-1.3")
    }

    func testParseFileSkipsLinesWithoutUsageEvents() {
        let file = record() + Data("\n".utf8)
            + Data(#"{"payload_type":"runtime.session","payload":{"kind":"security_mode"}}"#.utf8)
            + Data("\n".utf8) + record()
        XCTAssertEqual(MuseUsageScanner.parseFile(file).count, 2)
    }

    // MARK: - Dedup and aggregation

    func testDedupDropsExactReplays() {
        let entries = [MuseUsageScanner.recordEntry(record())!, MuseUsageScanner.recordEntry(record())!]
        XCTAssertEqual(MuseUsageScanner.dedup(entries).count, 1)
    }

    func testAggregatePricesThroughTheEngine() {
        // (2000 × 1.25 + 8000 × 0.15 + 600 × 4.25) / 1e6 = 0.00625
        let scan = MuseUsageScanner.aggregate(
            entries: [MuseUsageScanner.recordEntry(record())!],
            since: .distantPast, pricing: pricing
        )
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.00625, accuracy: 0.000_001)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 10_600)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }

    func testAggregatePricesContributorSuffixAtDiscount() {
        let entry = MuseUsageScanner.recordEntry(record(model: "muse-spark-1.3-contributor"))!
        let scan = MuseUsageScanner.aggregate(entries: [entry], since: .distantPast, pricing: pricing)
        // (2000 × 0.1 + 8000 × 0.01 + 600 × 0.2) / 1e6 = 0.0004
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.0004, accuracy: 0.000_001)
    }

    func testAggregateExcludesUnpricedModelsWithAWarning() {
        let entry = MuseUsageScanner.recordEntry(record(model: "muse-spark-9.9"))!
        let scan = MuseUsageScanner.aggregate(entries: [entry], since: .distantPast, pricing: pricing)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay.values.first?.first, "muse-spark-9.9")
    }

    func testAggregateHonorsTheWindowCutoff() {
        let old = MuseUsageScanner.recordEntry(
            record(at: Date(timeIntervalSince1970: 1_000_000)))!
        let scan = MuseUsageScanner.aggregate(entries: [old], since: Date(), pricing: pricing)
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    // MARK: - File discovery

    private func homeWithSessions(files: [String: Data]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseTests-\(UUID().uuidString)")
        for (relative, data) in files {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return home
    }

    private func sessionPath(id: String = "s1") -> String {
        ".local/share/muse/sessions/2026/09/05/\(id)/session.jsonl"
    }

    private func makeScanner(home: URL) -> MuseUsageScanner {
        MuseUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner()
        )
    }

    func testHasLocalUsageReflectsLogFilesOnDisk() async throws {
        let empty = try homeWithSessions(files: [:])
        defer { try? FileManager.default.removeItem(at: empty) }
        let emptyHasUsage = await makeScanner(home: empty).hasLocalUsage()
        XCTAssertFalse(emptyHasUsage)

        let home = try homeWithSessions(files: [sessionPath(): record()])
        defer { try? FileManager.default.removeItem(at: home) }
        let homeHasUsage = await makeScanner(home: home).hasLocalUsage()
        XCTAssertTrue(homeHasUsage)
    }

    func testScanSkipsMirroredSubagentTranscripts() async throws {
        let now = Date()
        let event = record(at: now)
        let home = try homeWithSessions(files: [
            sessionPath(): event,
            ".local/share/muse/sessions/2026/09/05/s1/subagent/child/session.jsonl": event
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await makeScanner(home: home).scan(now: now, pricing: pricing)
        // One copy counted, not both: the child's steps are already mirrored in the parent log.
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 10_600)
    }
}

// MARK: - Auth store

final class MuseAuthStoreTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseAuthTests-\(UUID().uuidString)")
    }

    private func authPath() -> String { home.path + "/.config/muse/auth.json" }

    private func store(
        files: [String: String] = [:], environment: [String: String] = [:]
    ) -> MuseAuthStore {
        let home = home!
        return MuseAuthStore(
            files: FakeFiles(files),
            environment: FakeEnvironment(environment),
            homeDirectory: { home }
        )
    }

    func testAbsentFileMeansNotLoggedIn() throws {
        XCTAssertNil(try store().credential())
    }

    func testEmptyFileMeansNotLoggedIn() throws {
        XCTAssertNil(try store(files: [authPath(): "  \n"]).credential())
    }

    func testPresentFileMeansAccountLogin() throws {
        XCTAssertEqual(
            try store(files: [authPath(): #"{"token":"x"}"#]).credential(), .accountLogin)
    }

    func testApiKeyEnvironmentWinsWithoutAnyFile() throws {
        XCTAssertEqual(try store(environment: ["META_API_KEY": "k"]).credential(), .apiKey)
    }

    func testAuthPathOverrideNamesTheFile() throws {
        let custom = home.path + "/custom-auth.json"
        let store = store(files: [custom: "{}"], environment: ["MUSE_AUTH_PATH": custom])
        XCTAssertEqual(try store.credential(), .accountLogin)
    }

    func testXDGConfigHomeRelocatesAuthFile() throws {
        let xdg = home.path + "/xdg"
        let store = store(
            files: [xdg + "/muse/auth.json": "{}"],
            environment: ["XDG_CONFIG_HOME": xdg]
        )
        XCTAssertEqual(try store.credential(), .accountLogin)
    }
}

// MARK: - Provider

@MainActor
final class MuseProviderRefreshTests: XCTestCase {
    private func pricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(pricing: [
                "muse-spark-1.3": ModelRates(
                    inputPerMillion: 1.25, outputPerMillion: 4.25,
                    cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.15
                )
            ]),
            primary: PricingCatalog(entries: [:]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func makeProvider(home: URL, files: [String: String], now: Date) -> MuseProvider {
        let environment = FakeEnvironment([:])
        let pricing = pricing()
        return MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(files), environment: environment,
                homeDirectory: { home }),
            usageScanner: MuseUsageScanner(
                environment: environment, homeDirectory: { home },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: MuseQuotaClient(
                http: RoutingHTTPClient { _ in
                    XCTFail("quota probe must not run without a key in scanner tests")
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                },
                keychain: FakeKeychain(nil),
                environment: FakeEnvironment([:])),
            now: { now },
            pricing: { pricing }
        )
    }

    private func sessionRecord(at date: Date) -> Data {
        let micros = Int64(date.timeIntervalSince1970 * 1_000_000)
        let json = """
        {"schema_version":1,"id":"r1","stream":{"kind":"session","id":"s1"},"sequence":1,\
        "recorded_at":\(micros),"record_type":"event","payload_type":"runtime.session",\
        "payload":{"kind":"run","event":{"kind":"model_completed",\
        "usage":{"input_tokens":10000,"output_tokens":500,"cached_tokens":8000,\
        "cache_read_tokens":8000,"cache_write_tokens":0,"reasoning_tokens":100},\
        "duration_ms":100,"model":"muse-spark-1.3"}}}
        """
        return Data(json.utf8)
    }

    func testNoCredentialAndNoLogsReportsNotLoggedIn() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = makeProvider(home: home, files: [:], now: Date())

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
    }

    func testLoggedInWithoutLogsShowsNoDataRatherThanAnError() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = makeProvider(
            home: home, files: [home.path + "/.config/muse/auth.json": "{}"], now: Date())

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines, [.noUsageData])
    }

    func testSessionLogProducesTodaySpendAndTrend() async throws {
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let datePath = String(
            format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseProviderTests-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".local/share/muse/sessions/\(datePath)/s1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sessionRecord(at: now).write(to: dir.appendingPathComponent("session.jsonl"))
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = makeProvider(
            home: home, files: [home.path + "/.config/muse/auth.json": "{}"], now: now)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
    }

    func testProbeFindsLogsWithoutAnyCredential() async {
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: MuseQuotaClient(
                http: RoutingHTTPClient { _ in
                    XCTFail("quota probe must not run without a key in scanner tests")
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                },
                keychain: FakeKeychain(nil),
                environment: FakeEnvironment([:]))
        )
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
    }
}
