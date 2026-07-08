import XCTest
@testable import OpenUsage

// MARK: - Sample payloads
/// Mirrors the undocumented Z.ai internal-API shapes the legacy Tauri plugin relied on, captured in
/// `docs/providers/zai.md`. These endpoints are not in Z.ai's public API reference but are stable in
/// practice (used by Z.ai's own subscription UI).

private let quotaBothLimitsJSON = #"""
{
  "code": 200,
  "data": {
    "limits": [
      {
        "type": "TOKENS_LIMIT",
        "unit": 3,
        "number": 5,
        "usage": 800000000,
        "currentValue": 127694464,
        "remaining": 672305536,
        "percentage": 15,
        "nextResetTime": 1770648402389
      },
      {
        "type": "TOKENS_LIMIT",
        "unit": 6,
        "number": 1,
        "percentage": 40,
        "nextResetTime": 1771300000000
      },
      {
        "type": "TIME_LIMIT",
        "unit": 5,
        "number": 1,
        "usage": 4000,
        "currentValue": 1828,
        "remaining": 2172,
        "percentage": 45,
        "usageDetails": [
          { "modelCode": "search-prime", "usage": 1433 },
          { "modelCode": "web-reader", "usage": 462 },
          { "modelCode": "zread", "usage": 0 }
        ]
      }
    ]
  },
  "success": true
}
"""#

private let quotaSessionOnlyJSON = #"""
{
  "code": 200,
  "data": {
    "limits": [
      { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "usage": 800000000, "currentValue": 0, "percentage": 0 }
    ]
  },
  "success": true
}
"""#

private let subscriptionJSON = #"""
{
  "code": 200,
  "data": [
    {
      "id": "169359",
      "productName": "GLM Coding Max",
      "status": "VALID",
      "nextRenewTime": "2026-03-12"
    }
  ],
  "success": true
}
"""#

private func data(_ json: String) -> Data {
    Data(json.utf8)
}

// MARK: - ZAIAuthStoreTests

final class ZAIAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        // Config file wins so editing it to rotate the key isn't shadowed by a stale env value.
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#]),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "zai-file")
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() {
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "zai-env")
    }

    func testAcceptsLegacyGLMEnvName() {
        // GLM_API_KEY is the older Zhipu name some users still export.
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["GLM_API_KEY": "glm-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "glm-env")
    }

    func testZAIKeyNameBeatsGLMKeyName() {
        // ZAI_API_KEY is primary; GLM_API_KEY only the fallback.
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai", "GLM_API_KEY": "glm"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai")
    }

    func testReadsKeyFromJSONConfigFile() {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{ "api_key": "zai-json" }"#]),
            environment: FakeEnvironment()
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "zai-json")
    }

    func testReadsPlainTextKeyFile() {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[1]: "  zai-plain\n"]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-plain")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    // MARK: - In-app save / delete / status (Settings ▸ API Keys)

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  zai-new  ")

        XCTAssertEqual(files.files[ZAIAuthStore.configPaths[0]], #"{"apiKey":"zai-new"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-new")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let files = FakeFiles()
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? ZAIAuthError, .missingKey)
        }
        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"]))

        try store.saveAPIKey("zai-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["ZAI_API_KEY": "zai-env"]
        let file = [ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#]

        XCTAssertEqual(ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(ZAIAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(ZAIAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }

    func testCurrentAPIKeyReturnsEffectiveKey() {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#]),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])
        )
        XCTAssertEqual(store.currentAPIKey(), "zai-file")
    }

    func testDeleteAPIKeyFallsBackToEnvironment() throws {
        let files = FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"]))

        XCTAssertEqual(store.keyStatus(), .overrideActive)
        try store.deleteAPIKey()

        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-env")
    }

    func testDeleteAPIKeyBecomesNotSetWhenNoEnvKey() throws {
        let files = FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-file"}"#])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
        XCTAssertEqual(store.keyStatus(), .notSet)
        XCTAssertNil(store.loadAPIKey())
    }

    func testDeleteAPIKeyIsNoOpWhenFileMissing() throws {
        let store = ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testDeleteAPIKeyClearsAllConfigPaths() throws {
        // A key in the alternate config path must also be cleared, or it resurfaces after the primary
        // file is deleted and the Settings "clear" appears not to work.
        let files = FakeFiles([
            ZAIAuthStore.configPaths[0]: #"{"apiKey":"zai-primary"}"#,
            ZAIAuthStore.configPaths[1]: "zai-alt"
        ])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[ZAIAuthStore.configPaths[0]])
        XCTAssertNil(files.files[ZAIAuthStore.configPaths[1]])
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

// MARK: - ZAIUsageMapperTests

final class ZAIUsageMapperTests: XCTestCase {
    func testMapsBothLimitsToSessionAndWebSearches() throws {
        let mapped = ZAIUsageMapper.map(quotaBody: data(quotaBothLimitsJSON), subscriptionBody: data(subscriptionJSON))

        XCTAssertEqual(mapped.plan, "GLM Coding Max")

        let session = try XCTUnwrap(progress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 15, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)
        // nextResetTime is epoch ms 1770648402389
        let resetsInterval = try XCTUnwrap(session.resetsAt?.timeIntervalSince1970)
        XCTAssertEqual(resetsInterval, 1770648402.389, accuracy: 0.1)

        // The second TOKENS_LIMIT (unit: 6, weeks) maps to the Weekly meter.
        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 40, accuracy: 0.001)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.format, .percent)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        let web = try XCTUnwrap(progress(mapped.lines, "Web Searches"))
        XCTAssertEqual(web.used, 1828, accuracy: 0.001)
        XCTAssertEqual(web.limit, 4000, accuracy: 0.001)
        XCTAssertEqual(web.format, .count(suffix: "searches"))
        XCTAssertEqual(web.periodDurationMs, 30 * 24 * 60 * 60 * 1000)
    }

    func testMeterWindowsFollowThePayloadNotTheHistoricConstants() throws {
        // The meters carry the payload-computed window, not hardcoded 5h/7d — a 3-hour session window
        // and a 3-day "weekly" window (unit 4 = days, multi-day → the Weekly meter) must plumb through.
        let divergentJSON = #"""
        {
          "code": 200,
          "data": {
            "limits": [
              { "type": "TOKENS_LIMIT", "unit": 3, "number": 3, "percentage": 10 },
              { "type": "TOKENS_LIMIT", "unit": 4, "number": 3, "percentage": 20 }
            ]
          },
          "success": true
        }
        """#
        let mapped = ZAIUsageMapper.map(quotaBody: data(divergentJSON), subscriptionBody: nil)
        XCTAssertEqual(try XCTUnwrap(progress(mapped.lines, "Session")).periodDurationMs,
                       3 * 60 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(progress(mapped.lines, "Weekly")).periodDurationMs,
                       3 * 24 * 60 * 60 * 1000)
    }

    func testMapsSessionOnlyWhenNoTimeLimit() throws {
        let mapped = ZAIUsageMapper.map(quotaBody: data(quotaSessionOnlyJSON), subscriptionBody: nil)

        XCTAssertNil(mapped.plan)
        XCTAssertNotNil(progress(mapped.lines, "Session"))
        XCTAssertNil(progress(mapped.lines, "Web Searches"))
    }

    func testPlanNameFromSubscription() {
        XCTAssertEqual(ZAIUsageMapper.planName(from: data(subscriptionJSON)), "GLM Coding Max")
    }

    func testPlanNameNilWhenNoData() {
        XCTAssertNil(ZAIUsageMapper.planName(from: data(#"{"data":[]}"#)))
    }

    func testEmptyLimitsYieldNoUsageData() {
        let mapped = ZAIUsageMapper.map(quotaBody: data(#"{"data":{"limits":[]}}"#), subscriptionBody: nil)
        // No usable limits → the shared "No usage data" placeholder, not a blank tile.
        XCTAssertTrue(mapped.lines.contains { $0.label == "Status" })
    }

    func testDetectsNoCodingPlanBody() {
        // A valid key on an account with no GLM Coding Plan: the live quota endpoint answers 2xx with
        // `success:false` / "…coding plan" (captured verbatim from the real API).
        XCTAssertTrue(ZAIUsageMapper.isNoCodingPlan(data(#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#)))
    }

    func testIsNoCodingPlanFalseForUsableOrUnrelatedBodies() {
        // A real quota payload and an unrelated business failure are both not "no coding plan".
        XCTAssertFalse(ZAIUsageMapper.isNoCodingPlan(data(quotaBothLimitsJSON)))
        XCTAssertFalse(ZAIUsageMapper.isNoCodingPlan(data(#"{"code":500,"msg":"internal error","success":false}"#)))
    }

    func testClampsAboveRangePercentage() throws {
        let body = data(#"""
        {"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":150,"currentValue":10,"usage":10}]}}
        """#)
        let lines = ZAIUsageMapper.mapQuota(body)
        let sessionUsed = try XCTUnwrap(progress(lines, "Session")?.used)
        XCTAssertEqual(sessionUsed, 100, accuracy: 0.001)
    }

    func testWeeklyOnlyWhenSessionAbsent() throws {
        // A single weekly TOKENS_LIMIT (no session entry) still maps the Weekly meter.
        let body = data(#"""
        {"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":25}]}}
        """#)
        let lines = ZAIUsageMapper.mapQuota(body)
        XCTAssertNil(progress(lines, "Session"))
        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertEqual(weekly.used, 25, accuracy: 0.001)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }
}

// MARK: - ZAIProviderTests

@MainActor
final class ZAIProviderTests: XCTestCase {
    func testRefreshMapsBothEndpoints() async throws {
        let provider = ZAIProvider(
            authStore: makeAuthStore(key: "zai-test"),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer zai-test")
                if request.url == ZAIUsageClient.quotaURL {
                    return jsonResponse(quotaBothLimitsJSON)
                }
                return jsonResponse(subscriptionJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "GLM Coding Max")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Web Searches"))
    }

    func testRefreshSurvivesSubscriptionFailure() async {
        // The subscription endpoint is best-effort (plan name only) — a failure there must not blank
        // out the quota meters.
        let provider = ZAIProvider(
            authStore: makeAuthStore(key: "zai-test"),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return jsonResponse(quotaBothLimitsJSON)
                }
                return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.plan)
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        let provider = ZAIProvider(
            authStore: makeAuthStore(key: "zai-bad"),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshOnNon2xxReportsRequestFailed() async {
        let provider = ZAIProvider(
            authStore: makeAuthStore(key: "zai-test"),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
                }
                return jsonResponse(subscriptionJSON)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testRefreshOnTransportErrorReportsNetwork() async {
        let provider = ZAIProvider(
            authStore: makeAuthStore(key: "zai-test"),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in
                throw ZAIUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testRefreshWithoutCodingPlanReportsNotAvailable() async {
        // A valid key whose account has no GLM Coding Plan: the quota endpoint answers a 2xx with
        // `success:false`. Surface a clear (non-malfunction) error so the header explains the empty card.
        let provider = ZAIProvider(
            authStore: makeAuthStore(key: "zai-test"),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return jsonResponse(#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#)
                }
                return jsonResponse(subscriptionJSON)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        guard case .badge(_, let text, _, _) = snapshot.lines.first else {
            return XCTFail("expected an error badge")
        }
        XCTAssertTrue(text.contains("GLM Coding Plan"))
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: files, environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "zai-env")
        XCTAssertEqual(provider.apiKeyEnvironmentName, "ZAI_API_KEY")
        XCTAssertTrue(provider.apiKeyStorageDescription.contains("zai.json"))

        try provider.saveAPIKey("zai-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "zai-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    func testProviderIdentityAndLinks() {
        let provider = ZAIProvider()
        XCTAssertEqual(provider.provider.id, "zai")
        XCTAssertEqual(provider.provider.displayName, "Z.ai")
        // Console + API Keys quick links render in the card's expanded area.
        XCTAssertEqual(provider.provider.visibleLinks.count, 2)
    }

    private func makeAuthStore(key: String) -> ZAIAuthStore {
        ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": key]))
    }
}

private func jsonResponse(_ jsonString: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(jsonString.utf8))
}
