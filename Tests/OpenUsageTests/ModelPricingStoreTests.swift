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

    /// An app update ships a newer bundled supplement while the cache from the previous version is
    /// still on disk. The shipped rates must win until the feed catches up — otherwise a fix that
    /// merged and shipped stays invisible, permanently for anyone who can't reach the feed.
    func testNewerBundledSupplementBeatsOlderCache() async throws {
        try writeSupplementCache(updatedAt: "2026-01-01", autoInput: 9)

        let store = makeStoreWithBundledSupplement(updatedAt: "2026-06-01", autoInput: 4)
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 4)
    }

    /// Multiple supplement changes can land on one day. A precise bundled timestamp must beat a
    /// legacy date-only cache from that day, or the cache hides newly shipped aliases and rates.
    func testTimestampedBundledSupplementBeatsSameDayDateOnlyCache() async throws {
        try writeSupplementCache(updatedAt: "2026-08-11", autoInput: 9)

        let store = makeStoreWithBundledSupplement(updatedAt: "2026-08-11T07:01:30Z", autoInput: 4)
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 4)
    }

    /// The usual case: the feed runs ahead of the shipped file, so the cache keeps winning.
    func testNewerCachedSupplementBeatsOlderBundled() async throws {
        try writeSupplementCache(updatedAt: "2026-06-01", autoInput: 9)

        let store = makeStoreWithBundledSupplement(updatedAt: "2026-01-01", autoInput: 4)
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
    }

    /// An undated file never displaces a dated one, in either direction.
    func testUndatedSupplementNeverDisplacesDatedOne() async throws {
        try writeSupplementCache(updatedAt: nil, autoInput: 9)

        let datedBundle = await makeStoreWithBundledSupplement(updatedAt: "2026-06-01", autoInput: 4).current()
        XCTAssertEqual(datedBundle.resolve(model: "auto")?.inputPerMillion, 4)

        try writeSupplementCache(updatedAt: "2026-06-01", autoInput: 9)
        let undatedBundle = await makeStoreWithBundledSupplement(updatedAt: nil, autoInput: 4).current()
        XCTAssertEqual(undatedBundle.resolve(model: "auto")?.inputPerMillion, 9)
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
