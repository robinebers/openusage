import XCTest
@testable import OpenUsage

private let museQuotaSSEFixture = """
event: response.created
data: {"type":"response.created"}

event: response.subscription_usage
data: {"subscription":{"tier":"tier-123","weekly":{"resets_at":1789344000,"used_percent":49},"window":{"resets_at":1788858956,"used_percent":42,"window_duration_mins":300}},"type":"response.subscription_usage"}

data: [DONE]

"""

private let museKeychainFixture = #"{"access_token":"ignored-access","api_key":"kc-key","secret_schema_version":1}"#

private func makeQuotaClient(
    http: any HTTPClient,
    keychainValue: String? = nil,
    environment: [String: String] = [:],
    files: [String: String] = [:]
) -> MuseQuotaClient {
    MuseQuotaClient(
        http: http,
        keychain: FakeKeychain(keychainValue),
        environment: FakeEnvironment(environment),
        userStore: UserAPIKeyStore(
            configPaths: MuseQuotaClient.userConfigPaths,
            environmentNames: MuseQuotaClient.userEnvironmentNames,
            files: FakeFiles(files),
            environment: FakeEnvironment(environment),
            makeError: { MuseUsageError($0) }
        )
    )
}

private func okSSEClient(_ sse: String = museQuotaSSEFixture) -> FakeHTTPClient {
    FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(sse.utf8)))
}

final class MuseQuotaClientTests: XCTestCase {
    func testParseUsageEventReadsPercentsResetsAndTier() throws {
        let usage = try MuseQuotaClient.parseUsageEvent(from: museQuotaSSEFixture)

        XCTAssertEqual(usage.tier, "tier-123")
        XCTAssertEqual(usage.weeklyUsedPercent, 49)
        XCTAssertEqual(usage.windowUsedPercent, 42)
        XCTAssertEqual(usage.weeklyResetsAt, Date(timeIntervalSince1970: 1_789_344_000))
        XCTAssertEqual(usage.windowResetsAt, Date(timeIntervalSince1970: 1_788_858_956))
        XCTAssertEqual(usage.windowDurationMinutes, 300)
    }

    func testParseUsageEventStopsAtDoneWithoutUsage() {
        XCTAssertThrowsError(
            try MuseQuotaClient.parseUsageEvent(from: "event: response.completed\ndata: {\"type\":\"x\"}\n\ndata: [DONE]\n")
        ) { error in
            XCTAssertEqual(error as? MuseQuotaError, .missingUsageEvent)
        }
    }

    func testFetchQuotaSendsBearerProbeAndMapsMeters() async throws {
        let http = okSSEClient()
        let client = makeQuotaClient(http: http, keychainValue: museKeychainFixture)

        let key = try client.apiKey()
        XCTAssertEqual(key, "kc-key")
        let usage = try await client.fetchQuota(apiKey: try XCTUnwrap(key))

        XCTAssertEqual(usage.windowUsedPercent, 42)
        let authorizations = http.requests.compactMap { $0.headers["Authorization"] }
        XCTAssertEqual(authorizations, ["Bearer kc-key"])
        XCTAssertTrue(http.requests.allSatisfy { $0.url == MuseQuotaClient.responsesURL })
        let lines = MuseQuotaClient.quotaLines(usage: usage)
        XCTAssertEqual(museProgress(lines, "Session")?.used, 42)
        XCTAssertEqual(museProgress(lines, "Weekly")?.used, 49)
        XCTAssertEqual(museProgress(lines, "Session")?.limit, 100)
        XCTAssertEqual(
            museProgress(lines, "Session")?.resetsAt,
            Date(timeIntervalSince1970: 1_788_858_956))
    }

    func testFetchQuotaUnauthorized() async {
        let client = makeQuotaClient(
            http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())),
            keychainValue: museKeychainFixture)

        do {
            _ = try await client.fetchQuota(apiKey: "stale")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? MuseQuotaError, .unauthorized)
        }
    }

    func testStoreAloneSeesEnv() {
        let store = UserAPIKeyStore(
            configPaths: ["~/.config/openusage/muse.json"],
            environmentNames: ["META_API_KEY"],
            files: FakeFiles(),
            environment: FakeEnvironment(["META_API_KEY": "env-key"]),
            makeError: { MuseUsageError($0) }
        )
        XCTAssertEqual(store.environmentNames, ["META_API_KEY"])
        XCTAssertEqual(store.environment.value(for: "META_API_KEY"), "env-key")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        XCTAssertEqual(store.loadKey(), "env-key")
    }

    func testStoreSeesConfigFile() {
        let store = UserAPIKeyStore(
            configPaths: ["~/.config/openusage/muse.json"],
            environmentNames: ["META_API_KEY"],
            files: FakeFiles(["~/.config/openusage/muse.json": #"{"apiKey": "file-key"}"#]),
            environment: FakeEnvironment([:]),
            makeError: { MuseUsageError($0) }
        )
        XCTAssertEqual(store.loadKey(), "file-key")
    }

    func testApiKeyPrefersEnvironmentOverKeychain() throws {
        let client = MuseQuotaClient(
            http: FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data())),
            keychain: FakeKeychain(museKeychainFixture),
            environment: FakeEnvironment(["META_API_KEY": "env-key"]),
            userStore: UserAPIKeyStore(
                configPaths: MuseQuotaClient.userConfigPaths,
                environmentNames: MuseQuotaClient.userEnvironmentNames,
                files: FakeFiles(),
                environment: FakeEnvironment(["META_API_KEY": "env-key"]),
                makeError: { MuseUsageError($0) }
            ))

        XCTAssertEqual(try client.apiKey(), "env-key")
    }

    func testApiKeyNilWhenKeychainMissingOrMalformed() throws {
        for blob in [nil, "{broken-json", #"{"access_token":"only-access"}"#] {
            let client = makeQuotaClient(
                http: FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data())),
                keychainValue: blob)
            XCTAssertNil(try client.apiKey(), "blob: \(blob ?? "nil")")
        }
    }

    func testApiKeyPrefersSavedFileOverEnvAndKeychain() throws {
        let client = makeQuotaClient(
            http: FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data())),
            keychainValue: museKeychainFixture,
            environment: ["META_API_KEY": "env-key"],
            files: [MuseQuotaClient.userConfigPaths[0]: #"{"apiKey": "saved-key"}"#])

        XCTAssertEqual(try client.apiKey(), "saved-key")
    }

    func testPlanNameStripsProductPrefix() {
        XCTAssertEqual(MuseQuotaClient.planName(tier: "Muse Code Everyday Usage"), "Everyday Usage")
        XCTAssertEqual(MuseQuotaClient.planName(tier: "Muse Code High Usage"), "High Usage")
        XCTAssertEqual(MuseQuotaClient.planName(tier: "Muse Code Power Usage"), "Power Usage")
        XCTAssertEqual(MuseQuotaClient.planName(tier: "27681393394859588"), "27681393394859588")
        XCTAssertNil(MuseQuotaClient.planName(tier: nil))
        XCTAssertNil(MuseQuotaClient.planName(tier: "   "))
    }

    func testPlanNameOverrideReadsSharedSettings() {
        let settings = """
            {"accounts": [{"id": "muse-code", "provider": "muse_code",
              "provider_paths": {"plan_name": "Everyday Usage"}}]}
            """
        XCTAssertEqual(MuseQuotaClient.planNameOverride(from: settings), "Everyday Usage")

        let byId = """
            {"accounts": [{"id": "muse", "provider": "other",
              "provider_paths": {"plan_name": "  High Usage  "}}]}
            """
        XCTAssertEqual(MuseQuotaClient.planNameOverride(from: byId), "High Usage")

        XCTAssertNil(MuseQuotaClient.planNameOverride(from: #"{"accounts": []}"#))
        XCTAssertNil(MuseQuotaClient.planNameOverride(from: #"{"accounts": [{"id": "muse-code"}]}"#))
        XCTAssertNil(MuseQuotaClient.planNameOverride(
            from: #"{"accounts": [{"id": "muse-code", "provider_paths": {"plan_name": "  "}}]}"#))
        XCTAssertNil(MuseQuotaClient.planNameOverride(from: "not json"))
    }

    func testPlanNameOverrideMissingFileIsNil() {
        let client = makeQuotaClient(http: okSSEClient(), files: [:])
        XCTAssertNil(client.planNameOverride())
    }

    @MainActor
    func testMalformedKeychainBlobIsNeverSent() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("malformed credentials must not leave the machine")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(http: http, keychainValue: "{broken-json"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertNil(museProgress(snapshot.lines, "Session"))
    }
}

final class MuseQuotaProviderTests: XCTestCase {
    @MainActor
    func testRefreshPrependsQuotaMetersBeforeSpend() async throws {
        let http = okSSEClient()
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(http: http, keychainValue: museKeychainFixture),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.used, 42)
        XCTAssertEqual(museProgress(snapshot.lines, "Weekly")?.used, 49)
        XCTAssertEqual(snapshot.plan, "tier-123", "opaque tier passes through as the plan label")
        XCTAssertEqual(
            snapshot.lines.prefix(2).map(\.label), ["Session", "Weekly"],
            "quota meters lead, spend tiles follow")
        XCTAssertEqual(
            Set(provider.widgetDescriptors.map(\.id)).intersection(["muse.session", "muse.weekly"]),
            ["muse.session", "muse.weekly"])
        XCTAssertTrue(http.requests.count == 1, "one probe per refresh")
    }

    @MainActor
    func testRefreshWithoutKeySkipsQuotaAndSendsNothing() async throws {
        let http = RoutingHTTPClient { _ in
            XCTFail("no API key means no probe request")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        // No credential, no logs, no key: the honest logged-out snapshot, quota silently absent.
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertNil(museProgress(snapshot.lines, "Session"))
        XCTAssertNil(snapshot.plan)
    }

    @MainActor
    func testRefreshPrefersAttestedPlanOverOpaqueTier() async throws {
        let settings = """
            {"accounts": [{"id": "muse-code", "provider": "muse_code",
              "provider_paths": {"plan_name": "Everyday Usage"}}]}
            """
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(
                http: okSSEClient(), keychainValue: museKeychainFixture,
                files: [MuseQuotaClient.sharedSettingsPath: settings]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.used, 42)
        XCTAssertEqual(snapshot.plan, "Everyday Usage")
    }

    @MainActor
    func testSavedKeyRoundtripDrivesStatus() throws {
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(
                http: okSSEClient(), environment: [:], files: [:])
        )
        XCTAssertEqual(provider.apiKeyStatus, .notSet)

        try provider.saveAPIKey("saved-key")
        XCTAssertEqual(provider.apiKeyStatus, .saved)
        XCTAssertEqual(provider.currentAPIKey(), "saved-key")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .notSet)
        XCTAssertNil(provider.currentAPIKey())
    }
}

private func museProgress(_ lines: [MetricLine], _ label: String) -> (
    used: Double, limit: Double, resetsAt: Date?
)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, _, _) =
        lines.first(where: { $0.label == label })
    else {
        return nil
    }
    return (used, limit, resetsAt)
}
