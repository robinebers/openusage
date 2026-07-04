import XCTest
@testable import OpenUsage

final class OpenRouterAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        // Config file wins so editing it to rotate the key isn't shadowed by a stale env value.
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "sk-or-file")
        XCTAssertEqual(auth?.source, .configFile)
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() {
        let store = OpenRouterAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "sk-or-env")
        XCTAssertEqual(auth?.source, .environment)
    }

    func testReadsKeyFromJSONConfigFile() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{ "api_key": "sk-or-json" }"#]),
            environment: FakeEnvironment()
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "sk-or-json")
        XCTAssertEqual(auth?.source, .configFile)
    }

    func testReadsPlainTextKeyFile() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[1]: "  sk-or-plain\n"]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-plain")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testIgnoresBlankConfigAndUsesEnvironment() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: "   "]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-env")
    }

    // MARK: - In-app save / delete / status (Settings ▸ API Keys)

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  sk-or-new  ")

        // Sorted-keys JSON, trimmed key — the exact bytes the auth store round-trips.
        XCTAssertEqual(files.files[OpenRouterAuthStore.configPaths[0]], #"{"apiKey":"sk-or-new"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-new")
        XCTAssertEqual(store.loadAPIKey()?.source, .configFile)
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .missingKey)
        }
        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
    }

    func testSavedKeyOverridesEnvironment() throws {
        // Saving writes the config file, which the auth store checks before the env var — so the
        // saved key wins and the status reports overrideActive.
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]))

        try store.saveAPIKey("sk-or-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["OPENROUTER_API_KEY": "sk-or-env"]
        let file = [OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]

        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }

    func testKeyStatusOverrideActiveEvenWhenKeysMatch() {
        // A saved key plus an env key is an override regardless of whether the values match — config
        // wins, so the saved source is the one in use. (Same key in two places still reads Custom.)
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-same"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-same"])
        )
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testCurrentAPIKeyReturnsEffectiveKey() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )
        XCTAssertEqual(store.currentAPIKey(), "sk-or-file")
    }

    func testDeleteAPIKeyFallsBackToEnvironment() throws {
        let files = FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]))

        XCTAssertEqual(store.keyStatus(), .overrideActive)
        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-env")
    }

    func testDeleteAPIKeyBecomesNotSetWhenNoEnvKey() throws {
        let files = FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
        XCTAssertEqual(store.keyStatus(), .notSet)
        XCTAssertNil(store.loadAPIKey())
    }

    func testDeleteAPIKeyIsNoOpWhenFileMissing() throws {
        // Removing a key that isn't there is the desired end state, not an error.
        let store = OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testDeleteAPIKeyClearsAllConfigPaths() throws {
        // A key in the alternate config path must also be cleared, or it resurfaces after the primary
        // file is deleted and the Settings "clear" appears not to work.
        let files = FakeFiles([
            OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-primary"}"#,
            OpenRouterAuthStore.configPaths[1]: "sk-or-alt"
        ])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[1]])
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testDeleteAPIKeyClearsAlternatePathOnly() throws {
        let files = FakeFiles([OpenRouterAuthStore.configPaths[1]: "sk-or-alt"])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertEqual(store.keyStatus(), .saved)
        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[1]])
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

final class OpenRouterUsageMapperTests: XCTestCase {
    func testCreditsLinesGiveMeterAndBalance() throws {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": 277.47, "total_usage": 178.20])

        let credits = try XCTUnwrap(progress(lines, "Credits"))
        XCTAssertEqual(credits.used, 178.20, accuracy: 0.001)
        XCTAssertEqual(credits.limit, 277.47, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(dollars(lines, "Balance")), 99.27, accuracy: 0.001)
    }

    func testCreditsLinesEmptyWithoutUsableTotal() {
        XCTAssertTrue(OpenRouterUsageMapper.creditsLines(from: ["foo": "bar"]).isEmpty)
    }

    func testNoCreditsMeterWhenNothingPurchased() {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": 0, "total_usage": 0])

        XCTAssertNil(progress(lines, "Credits"))
        // Balance is still shown as a real, measured zero — not "No data".
        XCTAssertEqual(dollars(lines, "Balance"), 0)
    }

    func testKeyMetricsGivePlanPeriodSpendAndCap() throws {
        let mapped = OpenRouterUsageMapper.keyMetrics(from: [
            "is_free_tier": false,
            "usage_daily": 0,
            "usage_weekly": 1.25,
            "usage_monthly": 4.5,
            "usage": 2,
            "limit": 5
        ])

        XCTAssertEqual(mapped.plan, "Pay as you go")
        // A real, measured zero is shown — not collapsed to "No data".
        XCTAssertEqual(dollars(mapped.lines, "Today"), 0)
        XCTAssertEqual(dollars(mapped.lines, "This Week"), 1.25)
        XCTAssertEqual(dollars(mapped.lines, "This Month"), 4.5)
        let keyLimit = try XCTUnwrap(progress(mapped.lines, "Key Limit"))
        XCTAssertEqual(keyLimit.used, 2)
        XCTAssertEqual(keyLimit.limit, 5)
    }

    func testKeyMetricsOmitCapWhenUnset() {
        let mapped = OpenRouterUsageMapper.keyMetrics(from: ["is_free_tier": true, "limit": NSNull()])

        XCTAssertEqual(mapped.plan, "Free tier")
        XCTAssertNil(progress(mapped.lines, "Key Limit"))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    func testRefreshMapsBothEndpoints() async throws {
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    XCTAssertEqual(request.headers["Authorization"], "Bearer sk-or-test")
                    return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
                }
                return jsonResponse(["data": ["is_free_tier": false, "usage_daily": 0.5]])
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pay as you go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertNotNil(snapshot.line(label: "Balance"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshSurvivesKeyEndpointFailure() async {
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
                }
                throw OpenRouterUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Balance"))
    }

    func testRefreshShowsKeyDataWhenCreditsForbidden() async {
        // If `/credits` is gated (403) but `/key` succeeds, still show the spend rows rather than erroring.
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                return jsonResponse(["data": ["is_free_tier": false, "usage_daily": 0.5, "usage_weekly": 2]])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Balance"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse([:])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        // Both endpoints reject the key — nothing usable comes back, so it's a hard auth failure.
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-bad"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshDoesNotReportInvalidKeyWhenOnlyCreditsForbidden() async {
        // `/credits` 403 (gated for this key type) but `/key` 200 — the key is valid, just gated for
        // credits. With no usable lines, the error must NOT be "invalid key" (it's not the key's fault).
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                // `/key` returns 200 but with no usable fields → no metric lines.
                return jsonResponse(["data": [:]])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotEqual(snapshot.errorCategory, .authInvalid)
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in jsonResponse([:]) })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "sk-or-env")
        XCTAssertEqual(provider.apiKeyEnvironmentName, "OPENROUTER_API_KEY")
        XCTAssertTrue(provider.apiKeyStorageDescription.contains("openrouter.json"))

        try provider.saveAPIKey("sk-or-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "sk-or-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    private func makeAuthStore(key: String) -> OpenRouterAuthStore {
        OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OPENROUTER_API_KEY": key]))
    }
}

private func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(statusCode: 200, headers: [:], body: body)
}

final class APIKeyManagementTests: XCTestCase {
    func testMaskedKeyPreviewHidesAllButLastFour() {
        XCTAssertEqual(maskedKeyPreview("sk-or-v1-abcdefgh"), "•••••••• efgh")
    }

    func testMaskedKeyPreviewTrimsWhitespace() {
        XCTAssertEqual(maskedKeyPreview("  sk-or-v1-abcdefgh\n"), "•••••••• efgh")
    }

    func testMaskedKeyPreviewReturnsNilForShortKey() {
        // A short secret would reveal too much — fall back to a fully-masked placeholder instead.
        XCTAssertNil(maskedKeyPreview("short"))
        XCTAssertNil(maskedKeyPreview("sk-or-12"))
    }

    func testAPIKeyStatusIsPresent() {
        XCTAssertFalse(APIKeyStatus.notSet.isPresent)
        XCTAssertTrue(APIKeyStatus.fromEnvironment.isPresent)
        XCTAssertTrue(APIKeyStatus.saved.isPresent)
        XCTAssertTrue(APIKeyStatus.overrideActive.isPresent)
    }
}
