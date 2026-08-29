import XCTest
@testable import OpenUsage

// MARK: - OrcaRouterAuthStoreTests

final class OrcaRouterAuthStoreTests: XCTestCase {
    func testLoadsConfigFormatsBeforeEnvironmentAndSkipsBlankValues() {
        let primary = OrcaRouterAuthStore.configPaths[0]
        let alternate = OrcaRouterAuthStore.configPaths[1]
        let cases: [(name: String, files: [String: String], environment: [String: String], expected: String)] = [
            ("saved override", [primary: #"{"apiKey":"sk-orca-file"}"#], ["ORCAROUTER_API_KEY": "sk-orca-env"], "sk-orca-file"),
            ("environment fallback", [:], ["ORCAROUTER_API_KEY": "sk-orca-env"], "sk-orca-env"),
            ("legacy JSON key", [primary: #"{"api_key":"sk-orca-json"}"#], [:], "sk-orca-json"),
            ("trimmed plain text", [alternate: "  sk-orca-plain\n"], [:], "sk-orca-plain"),
            ("blank config", [primary: "   "], ["ORCAROUTER_API_KEY": "sk-orca-env"], "sk-orca-env")
        ]

        for entry in cases {
            let store = OrcaRouterAuthStore(files: FakeFiles(entry.files), environment: FakeEnvironment(entry.environment))
            XCTAssertEqual(store.loadAPIKey()?.apiKey, entry.expected, entry.name)
        }
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = OrcaRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    // MARK: - In-app save / delete / status (Customize → OrcaRouter → API Key)

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = OrcaRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  sk-orca-new  ")

        XCTAssertEqual(files.files[OrcaRouterAuthStore.configPaths[0]], #"{"apiKey":"sk-orca-new"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-orca-new")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let files = FakeFiles()
        let store = OrcaRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? OrcaRouterAuthError, .missingKey)
        }
        XCTAssertNil(files.files[OrcaRouterAuthStore.configPaths[0]])
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = OrcaRouterAuthStore(files: files, environment: FakeEnvironment(["ORCAROUTER_API_KEY": "sk-orca-env"]))

        try store.saveAPIKey("sk-orca-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-orca-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["ORCAROUTER_API_KEY": "sk-orca-env"]
        let file = [OrcaRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-orca-file"}"#]

        XCTAssertEqual(OrcaRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(OrcaRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(OrcaRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(OrcaRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }

    func testCurrentAPIKeyReturnsEffectiveKey() {
        let store = OrcaRouterAuthStore(
            files: FakeFiles([OrcaRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-orca-file"}"#]),
            environment: FakeEnvironment(["ORCAROUTER_API_KEY": "sk-orca-env"])
        )
        XCTAssertEqual(store.currentAPIKey(), "sk-orca-file")
    }

    func testDeleteClearsPrimaryAndAlternatePathsWithEnvironmentFallback() throws {
        let cases: [(paths: [Int], environment: [String: String])] = [
            ([0], ["ORCAROUTER_API_KEY": "sk-orca-env"]),
            ([0], [:]),
            ([0, 1], [:]),
            ([1], [:])
        ]

        for entry in cases {
            let contents = Dictionary(uniqueKeysWithValues: entry.paths.map {
                (OrcaRouterAuthStore.configPaths[$0], $0 == 0 ? #"{"apiKey":"sk-orca-primary"}"# : "sk-orca-alt")
            })
            let files = FakeFiles(contents)
            let store = OrcaRouterAuthStore(files: files, environment: FakeEnvironment(entry.environment))

            try store.deleteAPIKey()

            for path in OrcaRouterAuthStore.configPaths { XCTAssertNil(files.files[path], path) }
            XCTAssertEqual(store.loadAPIKey()?.apiKey, entry.environment["ORCAROUTER_API_KEY"])
            XCTAssertEqual(store.keyStatus(), entry.environment.isEmpty ? .notSet : .fromEnvironment)
        }
    }

    func testDeleteAPIKeyIsNoOpWhenFileMissing() throws {
        let store = OrcaRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

// MARK: - OrcaRouterUsageMapperTests

final class OrcaRouterUsageMapperTests: XCTestCase {
    func testUsageLineReadsTotalSpend() {
        let line = OrcaRouterUsageMapper.usageLine(from: ["object": "list", "total_usage": 122560.35])

        guard case .values(_, let values, _, _, _, _) = line else {
            return XCTFail("expected a values line")
        }
        XCTAssertEqual(values.first?.number, 122560.35, accuracy: 0.001)
        XCTAssertEqual(values.first?.kind, .dollars)
    }

    func testUsageLineNilWithoutTotal() {
        XCTAssertNil(OrcaRouterUsageMapper.usageLine(from: ["object": "list"]))
    }

    func testBalanceLinesGiveWalletAndFreeCredit() {
        let lines = OrcaRouterUsageMapper.balanceLines(from: [
            "object": "balance",
            "unit": "USD",
            "paid_balance": 100.0,
            "free_credit": [
                ["model": "orca/dub", "balance": 50.0, "balance_usd": 50.0]
            ]
        ])

        XCTAssertEqual(dollars(lines, "Balance"), 100.0)
        XCTAssertEqual(dollars(lines, "Free Credit"), 50.0)
    }

    func testBalanceLinesSumFreeCreditsAcrossModels() {
        let lines = OrcaRouterUsageMapper.balanceLines(from: [
            "paid_balance": 0,
            "free_credit": [
                ["model": "a", "balance_usd": 10.0],
                ["model": "b", "balance_usd": 20.0]
            ]
        ])

        XCTAssertEqual(dollars(lines, "Free Credit"), 30.0)
    }

    func testBalanceLinesEmptyWithoutUsableFields() {
        XCTAssertTrue(OrcaRouterUsageMapper.balanceLines(from: ["object": "balance"]).isEmpty)
    }

    func testBalanceKeepsNegativeWallet() {
        // Usage past the funded amount is real data — shown raw, not clamped to zero.
        let lines = OrcaRouterUsageMapper.balanceLines(from: ["paid_balance": -6.5, "free_credit": []])
        XCTAssertEqual(dollars(lines, "Balance"), -6.5)
        XCTAssertNil(dollars(lines, "Free Credit"))
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

// MARK: - OrcaRouterProviderTests

@MainActor
final class OrcaRouterProviderTests: XCTestCase {
    func testRefreshMapsBothEndpoints() async throws {
        let provider = OrcaRouterProvider(
            authStore: makeAuthStore(key: "sk-orca-test"),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OrcaRouterUsageClient.usageURL {
                    XCTAssertEqual(request.headers["Authorization"], "Bearer sk-orca-test")
                    return jsonResponse(["object": "list", "total_usage": 122560.35])
                }
                XCTAssertEqual(request.url.absoluteString, OrcaRouterUsageClient.balanceURL)
                return jsonResponse(["object": "balance", "unit": "USD", "paid_balance": 100.0, "free_credit": []])
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Total Usage"))
        XCTAssertNotNil(snapshot.line(label: "Balance"))
    }

    func testRefreshSurvivesBalanceEndpointFailure() async {
        let provider = OrcaRouterProvider(
            authStore: makeAuthStore(key: "sk-orca-test"),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OrcaRouterUsageClient.usageURL {
                    return jsonResponse(["object": "list", "total_usage": 42.0])
                }
                throw OrcaRouterUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Total Usage"))
        XCTAssertNil(snapshot.line(label: "Balance"))
    }

    func testRefreshShowsBalanceWhenUsageForbidden() async {
        // If `/usage` is gated (403) but `/balance` succeeds, still show the balance rather than erroring.
        let provider = OrcaRouterProvider(
            authStore: makeAuthStore(key: "sk-orca-test"),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OrcaRouterUsageClient.usageURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                return jsonResponse(["object": "balance", "unit": "USD", "paid_balance": 5.0, "free_credit": []])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Balance"))
        XCTAssertNil(snapshot.line(label: "Total Usage"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = OrcaRouterProvider(
            authStore: OrcaRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse([:])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        let provider = OrcaRouterProvider(
            authStore: makeAuthStore(key: "sk-orca-bad"),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshDoesNotReportInvalidKeyWhenOnlyUsageForbidden() async {
        // `/usage` 403 (gated for this key type) but `/balance` 200 — the key is valid, just gated for
        // usage. With no usable lines, the error must NOT be "invalid key" (it's not the key's fault).
        let provider = OrcaRouterProvider(
            authStore: makeAuthStore(key: "sk-orca-test"),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OrcaRouterUsageClient.usageURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                return jsonResponse(["object": "balance", "unit": "USD"])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotEqual(snapshot.errorCategory, .authInvalid)
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = OrcaRouterProvider(
            authStore: OrcaRouterAuthStore(files: files, environment: FakeEnvironment(["ORCAROUTER_API_KEY": "sk-orca-env"])),
            usageClient: OrcaRouterUsageClient(http: RoutingHTTPClient { _ in jsonResponse([:]) })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "sk-orca-env")

        try provider.saveAPIKey("sk-orca-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "sk-orca-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    func testProviderIdentityAndLinks() {
        let provider = OrcaRouterProvider()
        XCTAssertEqual(provider.provider.id, "orcarouter")
        XCTAssertEqual(provider.provider.displayName, "OrcaRouter")
        XCTAssertEqual(provider.provider.links.first?.url, "https://www.orcarouter.ai/console")
    }

    private func makeAuthStore(key: String) -> OrcaRouterAuthStore {
        OrcaRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ORCAROUTER_API_KEY": key]))
    }
}

private func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(statusCode: 200, headers: [:], body: body)
}
