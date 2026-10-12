import XCTest
import SwiftUI
@testable import OpenUsage

final class DeepSeekAuthStoreTests: XCTestCase {
    func testCredentialPrecedenceAndAliases() {
        let path = DeepSeekAuthStore.configPaths[0]
        let cases: [(files: [String: String], environment: [String: String], expected: String?)] = [
            ([path: #"{"apiKey":"saved"}"#], ["DEEPSEEK_API_KEY": "env"], "saved"),
            ([:], ["DEEPSEEK_API_KEY": "primary", "DEEPSEEK_KEY": "alias"], "primary"),
            ([:], ["DEEPSEEK_API_KEY": "  ", "DEEPSEEK_KEY": " alias\n"], "alias"),
            ([path: #"{"api_key":" legacy "}"#], [:], "legacy"),
            ([path: " plain\n"], [:], "plain"),
            ([path: #"{"apiKey":" "}"#], ["DEEPSEEK_API_KEY": "env"], "env"),
            ([path: "{"], [:], nil),
            ([:], [:], nil)
        ]
        for entry in cases {
            let store = DeepSeekAuthStore(files: FakeFiles(entry.files), environment: FakeEnvironment(entry.environment))
            XCTAssertEqual(store.loadAPIKey(), entry.expected)
        }
    }

    func testSaveOverrideAndDeleteRestoreEnvironment() throws {
        let files = FakeFiles()
        let store = DeepSeekAuthStore(files: files, environment: FakeEnvironment(["DEEPSEEK_API_KEY": "env"]))
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        try store.saveAPIKey(" saved ")
        XCTAssertEqual(files.files[DeepSeekAuthStore.configPaths[0]], #"{"apiKey":"saved"}"#)
        XCTAssertEqual(store.currentAPIKey(), "saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
        try store.deleteAPIKey()
        XCTAssertEqual(store.currentAPIKey(), "env")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }

    func testSavedAndMissingStatusAndEmptyKeyRejection() throws {
        let store = DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertEqual(store.keyStatus(), .notSet)
        XCTAssertThrowsError(try store.saveAPIKey(" \n")) {
            XCTAssertEqual($0 as? DeepSeekAuthError, .missingKey)
        }
        try store.saveAPIKey("saved")
        XCTAssertEqual(store.keyStatus(), .saved)
        try store.deleteAPIKey()
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

final class DeepSeekUsageMapperTests: XCTestCase {
    func testMapsOfficialResponseAndPrefersUSDRegardlessOfOrder() throws {
        let balance = try DeepSeekUsageMapper.balance(from: fixture(infos: [
            balanceInfo(currency: "CNY", total: "60.00"),
            balanceInfo(total: "8.76", paid: "7.50", granted: "1.26")
        ]))
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.total, 8.76)
        XCTAssertEqual(balance.paid, 7.50)
        XCTAssertEqual(balance.granted, 1.26)
        XCTAssertNil(balance.warning)
        XCTAssertEqual(balance.lines.map(\.label), ["Balance", "Paid", "Granted"])
    }

    func testZeroBalanceAndUnavailableStatusRemainMeasuredValues() throws {
        let balance = try DeepSeekUsageMapper.balance(from: fixture(available: false, infos: [
            balanceInfo(total: "0.00", paid: "0.00", granted: "0.00")
        ]))
        XCTAssertEqual(balance.total, 0)
        XCTAssertEqual(balance.lines.count, 3)
        XCTAssertNotNil(balance.warning)
        let fundedButUnavailable = try DeepSeekUsageMapper.balance(from: fixture(available: false))
        XCTAssertEqual(fundedButUnavailable.total, 8.76)
        XCTAssertNotNil(fundedButUnavailable.warning)
    }

    func testCNYRetainsRawAmountAndExplicitCurrency() throws {
        let balance = try DeepSeekUsageMapper.balance(from: fixture(infos: [balanceInfo(currency: "CNY")]))
        XCTAssertEqual(balance.currency, "CNY")
        guard case .values(_, let values, _, _, _, _) = balance.lines[0] else {
            return XCTFail("Balance should carry a raw monetary value")
        }
        XCTAssertEqual(values.first?.number, 8.76)
        XCTAssertEqual(values.first?.currencyCode, "CNY")
        XCTAssertEqual(MetricFormatter.string(for: try XCTUnwrap(values.first), style: .row), "CNY 8.76")
    }

    func testMalformedAmountsDoNotBecomeZeroOrFallbackToAnotherCurrency() throws {
        for field in ["total_balance", "topped_up_balance", "granted_balance"] {
            for bad: Any in ["NaN", "Infinity", "invalid", true, NSNull()] {
                var info = balanceInfo()
                info[field] = bad
                assertInvalid(fixture(infos: [info, balanceInfo(currency: "CNY")]))
            }
            var info = balanceInfo()
            info.removeValue(forKey: field)
            assertInvalid(fixture(infos: [info]))
        }
    }

    func testMissingOrInvalidSchemaDoesNotProduceEmptySuccess() {
        for object: [String: Any] in [
            [:], ["balance_infos": [balanceInfo()]],
            ["is_available": true], ["is_available": true, "balance_infos": []],
            ["is_available": 1, "balance_infos": [balanceInfo()]],
            ["is_available": "false", "balance_infos": [balanceInfo()]],
            ["is_available": true, "balance_infos": ["not an object"]]
        ] {
            assertInvalid(jsonData(object))
        }
        assertInvalid(Data("not JSON".utf8))
    }

    func testUnsupportedCurrencyIsReportedExplicitly() {
        XCTAssertThrowsError(try DeepSeekUsageMapper.balance(from: fixture(infos: [balanceInfo(currency: "EUR")]))) {
            XCTAssertEqual($0 as? DeepSeekUsageError, .unsupportedCurrency)
        }
    }

    func testSignedAmountsArePreservedRatherThanClampedOrRejected() throws {
        let balance = try DeepSeekUsageMapper.balance(from: fixture(available: false, infos: [
            balanceInfo(total: "-0.01", paid: "-0.01", granted: "0.00")
        ]))
        XCTAssertEqual(balance.total, -0.01)
        XCTAssertEqual(balance.paid, -0.01)
        XCTAssertNotNil(balance.warning)
    }

    private func assertInvalid(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DeepSeekUsageMapper.balance(from: data), file: file, line: line) {
            XCTAssertEqual($0 as? DeepSeekUsageError, .invalidResponse, file: file, line: line)
        }
    }
}

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    func testRefreshUsesPublicBalanceEndpointAndBearerKey() async {
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.absoluteString, DeepSeekUsageClient.balanceURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer test-key")
            XCTAssertEqual(request.headers["Accept"], "application/json")
            return HTTPResponse(statusCode: 200, headers: [:], body: fixture())
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = makeProvider(http: http, now: { date })
        let snapshot = await provider.refresh()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(snapshot.providerID, "deepseek")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.refreshedAt, date)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Balance", "Paid", "Granted"])
    }

    func testLocalProbeAndMissingKeyNeverCallNetwork() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("Credential detection and missing-key refresh must stay local")
            return HTTPResponse(statusCode: 200, headers: [:], body: fixture())
        }
        let provider = DeepSeekProvider(
            authStore: DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: DeepSeekUsageClient(http: http)
        )
        let absent = await provider.hasLocalCredentials()
        XCTAssertFalse(absent)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        try? provider.saveAPIKey("saved")
        let present = await provider.hasLocalCredentials()
        XCTAssertTrue(present)
        let envProvider = makeProvider(http: http)
        let environmentPresent = await envProvider.hasLocalCredentials()
        XCTAssertTrue(environmentPresent)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testErrorCategoriesForAuthHTTPTransportAndMalformedData() async {
        let cases: [(status: Int, body: Data, category: ErrorCategory)] = [
            (401, Data(), .authInvalid), (403, Data(), .authInvalid),
            (429, Data(), ErrorCategory.http(429)), (500, Data(), ErrorCategory.http(500)),
            (200, Data("{}".utf8), .decoding), (204, Data(), .decoding)
        ]
        for entry in cases {
            let response = HTTPResponse(statusCode: entry.status, headers: [:], body: entry.body)
            let provider = makeProvider(http: RoutingHTTPClient { _ in response })
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, entry.category)
            XCTAssertTrue(snapshot.lines.allSatisfy(\.isError))
        }
        let offline = makeProvider(http: RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) })
        let snapshot = await offline.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testUnavailableBalancePreservesSuccessWithWarning() async {
        let provider = makeProvider(http: RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: fixture(available: false))
        })
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Balance"))
    }

    func testCurrencySurvivesSnapshotCacheAndAllWidgetSurfaces() async throws {
        let (provider, store) = await refreshedStore(currency: "CNY")
        let row = store.data(for: provider.widgetDescriptors[0])
        XCTAssertEqual(row.headline, "CNY 8.76")
        XCTAssertEqual(row.unboundedDetail, "CNY 8.76 left")
        XCTAssertEqual(row.menuBarValue, "CNY 9")
        XCTAssertNil(row.limit)
        let snapshot = await provider.refresh()
        let restored = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.lines, snapshot.lines)
        let legacy = try JSONDecoder().decode(MetricValue.self, from: Data(#"{"number":8.76,"kind":"dollars","estimated":false}"#.utf8))
        XCTAssertNil(legacy.currencyCode)
        XCTAssertEqual(MetricFormatter.string(for: legacy, style: .row), "$8.76")
    }

    func testRegistryDefaultsAndAPIKeyManagement() throws {
        let defaults = makeUserDefaults("deepseek-catalog")
        let providers = ProviderCatalog.make(defaults: defaults)
        XCTAssertNotNil(providers.first { $0.provider.id == "deepseek" } as? any APIKeyManaging)
        let ids = providers.map { $0.provider.id }
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: "copilot")), try XCTUnwrap(ids.firstIndex(of: "deepseek")))
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: "deepseek")), try XCTUnwrap(ids.firstIndex(of: "devin")))
        let provider = makeProvider(http: RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: fixture()) })
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["deepseek.balance", "deepseek.paid", "deepseek.granted"])
        for descriptor in provider.widgetDescriptors {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(descriptor.id))
            XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(descriptor.id))
            XCTAssertEqual(DefaultLayout.expandedMetricIDs.contains(descriptor.id), descriptor.id != "deepseek.balance")
        }
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        try provider.saveAPIKey("saved")
        XCTAssertEqual(provider.currentAPIKey(), "saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        try provider.deleteAPIKey()
        XCTAssertEqual(provider.currentAPIKey(), "test-key")
    }

    /// Uses the same resolved rows and SwiftUI card as the app's Share Screenshot action.
    /// Set OPENUSAGE_DEEPSEEK_SCREENSHOTS to export fixtures for visual review without real credentials.
    func testProviderCardsRenderWithUSDAndCNY() async throws {
        for currency in ["USD", "CNY"] {
            let (provider, store) = await refreshedStore(currency: currency)
            let rows = provider.widgetDescriptors.map { store.data(for: $0) }
            XCTAssertTrue(rows.allSatisfy(\.hasData))
            let card = ShareCardView(provider: provider.provider, rows: rows, appearance: .light, expandBoundaryIndex: 1)
            let png = try XCTUnwrap(ShareCardRenderer.pngData(from: try XCTUnwrap(ShareCardRenderer.image(for: card))))
            XCTAssertNotNil(NSImage(data: png))
            if let directory = ProcessInfo.processInfo.environment["OPENUSAGE_DEEPSEEK_SCREENSHOTS"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("deepseek-\(currency.lowercased()).png"))
            }
        }
    }

    private func makeProvider(http: any HTTPClient, now: @escaping @Sendable () -> Date = Date.init) -> DeepSeekProvider {
        DeepSeekProvider(
            authStore: DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment(["DEEPSEEK_API_KEY": "test-key"])),
            usageClient: DeepSeekUsageClient(http: http), now: now
        )
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suite = "DeepSeekTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func refreshedStore(currency: String) async -> (DeepSeekProvider, WidgetDataStore) {
        let body = fixture(infos: [balanceInfo(currency: currency, total: "8.76", paid: "7.50", granted: "1.26")])
        let provider = makeProvider(http: RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: body) })
        let defaults = makeUserDefaults("deepseek-\(currency)-render")
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([provider]), providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: Date.init),
            defaults: defaults
        )
        await store.refreshAll()
        return (provider, store)
    }
}

private func balanceInfo(currency: String = "USD", total: String = "8.76", paid: String = "8.76", granted: String = "0.00") -> [String: Any] {
    ["currency": currency, "total_balance": total, "topped_up_balance": paid, "granted_balance": granted]
}

private func fixture(available: Bool = true, infos: [[String: Any]] = [balanceInfo()]) -> Data {
    jsonData(["is_available": available, "balance_infos": infos])
}

private func jsonData(_ object: [String: Any]) -> Data {
    // Fixture serialization is an invariant of these tests; never replace bad fixtures with an empty body.
    try! JSONSerialization.data(withJSONObject: object)
}
