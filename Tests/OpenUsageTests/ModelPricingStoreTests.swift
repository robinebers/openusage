import XCTest
@testable import OpenUsage

/// Fetch/cache/TTL behavior of the pricing store, with stubbed HTTP, an injected clock, and tiny
/// fixture feeds.
final class ModelPricingStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static let bundledFixtures: @Sendable (String) -> Data? = { name in
        switch name {
        case "pricing_supplement":
            return Data("""
            {"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0}},
             "fast_multipliers": {}, "alias_rules": []}
            """.utf8)
        case "pricing_litellm_snapshot":
            return Data(#"{"models": {"bundled-model": {"i": 1, "o": 2, "cw": 1, "cr": 0.1}}}"#.utf8)
        case "pricing_models_dev_snapshot":
            return Data(#"{"models": {"bundled-dev-model": {"i": 3, "o": 4, "cw": 3, "cr": 0.3}}}"#.utf8)
        default:
            return nil
        }
    }

    private static let litellmFeed = """
    {"fetched-model": {"input_cost_per_token": 5e-06, "output_cost_per_token": 1e-05,
                       "cache_read_input_token_cost": 5e-07}}
    """

    private static let modelsDevFeed = """
    {"xai": {"models": {"fetched-dev-model": {"cost": {"input": 1, "output": 2, "cache_read": 0.2}}}}}
    """

    private static let supplementFeed = """
    {"pricing": {"auto": {"input_per_million": 9.0, "output_per_million": 9.0}},
     "fast_multipliers": {}, "alias_rules": []}
    """

    private func makeStore(
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> (ModelPricingStore, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let store = ModelPricingStore(
            http: http,
            cacheDirectory: tempDir,
            now: now,
            bundledData: Self.bundledFixtures
        )
        return (store, http)
    }

    private static func respond(to request: HTTPRequest) -> HTTPResponse {
        let body: String
        if request.url.absoluteString.contains("litellm") {
            body = litellmFeed
        } else if request.url.host() == "models.dev" {
            body = modelsDevFeed
        } else {
            body = supplementFeed
        }
        return HTTPResponse(statusCode: 200, headers: ["etag": "\"v1\""], body: Data(body.utf8))
    }

    func testServesBundledDataBeforeAnyFetch() async throws {
        let (store, _) = makeStore(handler: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "bundled-dev-model")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
    }

    func testNewerLegacyFeedKeepsBundledFallbackChoices() async throws {
        try Data("""
        {"updated_at": "2099-01-01T00:00:00Z", "pricing": {}, "alias_rules": []}
        """.utf8).write(to: tempDir.appendingPathComponent("supplement.json"))
        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                if name == "pricing_supplement" {
                    return Data("""
                    {"updated_at": "2026-08-01T00:00:00Z", "pricing": {}, "alias_rules": [],
                     "fallback_models": {"codex": ["gpt-5.6-sol"]}}
                    """.utf8)
                }
                return Self.bundledFixtures(name)
            }
        )

        let pricing = await store.current()
        XCTAssertEqual(pricing.supplement.updatedAt, "2099-01-01T00:00:00Z")
        XCTAssertEqual(pricing.supplement.fallbackModels["codex"], ["gpt-5.6-sol"])
        await store.refreshNow()
    }

    func testRefreshFetchesAllSourcesAndAppliesData() async throws {
        let (store, http) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()
        XCTAssertEqual(http.requests.count, 3)

        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "fetched-dev-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9, "fetched supplement replaces bundled")
        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1, "bundled entries survive the merge")
    }

    func testFeedRemovingSelectedFallbackRequestsRecalculationAndExcludesItsEstimates() async throws {
        let reference = "gpt-5.6-sol"
        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"updated_at":"2099-01-01", "pricing":{}, "alias_rules":[], "fallback_models":{"codex":[]}}
                """.utf8))
            }),
            cacheDirectory: tempDir,
            sourceURLs: [.supplement: URL(string: "https://example.com/supplement.json")!],
            bundledData: { name in
                guard name == "pricing_supplement" else { return Self.bundledFixtures(name) }
                return Data("""
                {"updated_at":"2026-08-01", "alias_rules":[], "fallback_models":{"codex":["gpt-5.6-sol"]},
                 "pricing":{"gpt-5.6-sol":{"input_per_million":5,"output_per_million":30}}}
                """.utf8)
            }
        )
        let event = CodexLogUsageScanner.Event(
            timestamp: Date(), model: "unlisted-model-a", input: 1_000, cached: 0, output: 100,
            reasoning: 0, total: 1_100, isFast: false
        )
        var refreshState = CodexFallbackPricingRefreshState()
        let initial = await store.current()
        XCTAssertTrue(refreshState.update(model: reference, options: initial.fallbackOptions(for: "codex")))
        let estimated = CodexLogUsageScanner.aggregate(
            events: [event], since: .distantPast, pricing: initial, fallbackModel: reference
        )
        XCTAssertEqual(try XCTUnwrap(estimated.series.daily.first?.costUSD), 0.008, accuracy: 0.000_001)

        await store.refreshNow()
        let refreshed = await store.current()
        XCTAssertTrue(refreshed.fallbackOptions(for: "codex").isEmpty)
        XCTAssertTrue(refreshState.update(model: reference, options: refreshed.fallbackOptions(for: "codex")))
        let recalculated = CodexLogUsageScanner.aggregate(
            events: [event], since: .distantPast, pricing: refreshed, fallbackModel: reference
        )
        XCTAssertTrue(recalculated.series.daily.isEmpty)
        XCTAssertNil(recalculated.fallbackPricingModelsByDay)
        XCTAssertEqual(recalculated.unknownModelsByDay, estimated.unknownModelsByDay)
    }

    func testCachePersistsAcrossStoreInstances() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        // Second store, network dead: cached fetch results still apply.
        let (revived, http) = makeStore(handler: { _ in throw URLError(.notConnectedToInternet) })
        let pricing = await revived.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
        // Fresh state file -> nothing due until the TTL elapses.
        await revived.refreshNow()
        XCTAssertTrue(http.requests.isEmpty, "sources within TTL must not refetch")
    }

    func testRefetchAfterTTLSendsETagAndHandles304() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, http) = makeStore(
            handler: { request in
                XCTAssertEqual(request.headers["If-None-Match"], "\"v1\"")
                return HTTPResponse(statusCode: 304, headers: [:], body: Data())
            },
            now: { later }
        )
        await aged.refreshNow()
        XCTAssertEqual(http.requests.count, 3, "all sources past TTL revalidate")

        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5, "304 keeps cached data")
    }

    func testFetchFailureKeepsServingCachedData() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, _) = makeStore(handler: { _ in
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }, now: { later })
        await aged.refreshNow()
        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
    }

    func testGarbageFeedDoesNotReplaceGoodCache() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, _) = makeStore(handler: { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))
        }, now: { later })
        await aged.refreshNow()
        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
    }

    func testSupplementSelectionPrefersTheMostRecentDatedSource() async throws {
        let scenarios: [(name: String, bundled: String?, cached: String?, expected: Double)] = [
            ("newer bundle", "2026-06-01", "2026-01-01", 4),
            ("same-day precise bundle", "2026-08-11T07:01:30Z", "2026-08-11", 4),
            ("newer cache", "2026-01-01", "2026-06-01", 9),
            ("undated cache", "2026-06-01", nil, 4),
            ("undated bundle", nil, "2026-06-01", 9)
        ]

        for scenario in scenarios {
            try writeSupplementCache(updatedAt: scenario.cached, autoInput: 9)
            let pricing = await makeStoreWithBundledSupplement(updatedAt: scenario.bundled, autoInput: 4).current()
            XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, scenario.expected, scenario.name)
        }
    }

    private static func supplementJSON(updatedAt: String?, autoInput: Double) -> String {
        let dateField = updatedAt.map { "\"updated_at\": \"\($0)\", " } ?? ""
        return """
        {\(dateField)"pricing": {"auto": {"input_per_million": \(autoInput), "output_per_million": 6.0}},
         "fast_multipliers": {}, "alias_rules": []}
        """
    }

    private func writeSupplementCache(updatedAt: String?, autoInput: Double) throws {
        try Data(Self.supplementJSON(updatedAt: updatedAt, autoInput: autoInput).utf8)
            .write(to: tempDir.appendingPathComponent("supplement.json"), options: .atomic)
    }

    /// A store whose bundled supplement carries `updatedAt`, with the network dead so only the
    /// cache-vs-bundled choice is under test.
    private func makeStoreWithBundledSupplement(updatedAt: String?, autoInput: Double) -> ModelPricingStore {
        let json = Self.supplementJSON(updatedAt: updatedAt, autoInput: autoInput)
        return ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_supplement" ? Data(json.utf8) : Self.bundledFixtures(name)
            }
        )
    }

    func testFailureRetryIntervalPreventsHammering() async throws {
        let counter = OSAllocatedUnfairLockedCounter()
        let (store, _) = makeStore(handler: { _ in
            counter.increment()
            throw URLError(.notConnectedToInternet)
        })
        await store.refreshNow()
        XCTAssertEqual(counter.value, 3)
        // Immediately after a failure, nothing is due.
        await store.refreshNow()
        XCTAssertEqual(counter.value, 3)
    }
}

/// Tiny thread-safe counter for request counting across Sendable closures.
private final class OSAllocatedUnfairLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
