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

// Fixture values are invented — never real account data. Shape mirrors
// POST muse-code/key.
private let museKeyFixture = """
{"subs_tier_id":"tier-999","subs_tier_name":"Muse Code Test Usage",\
"is_subs_upgrade_available":true,\
"subs_usage":{"window":{"used_percent":7,"window_duration_mins":300,\
"resets_at":1788858956},"weekly":{"used_percent":13,"resets_at":1789344000},\
"tier":"tier-999"}}
"""

private func makeQuotaClient(
    http: any HTTPClient,
    keychainValue: String? = nil,
    environment: [String: String] = [:],
    files: [String: String] = [:],
    memoryDirectory: URL? = nil
) -> MuseQuotaClient {
    // Fresh temp dir per client: successful probes persist attribution memory,
    // which must never land in the user's live state dir during tests.
    let directory = memoryDirectory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("muse-quota-memory-\(UUID().uuidString)")
    return MuseQuotaClient(
        http: http,
        keychain: FakeKeychain(keychainValue),
        environment: FakeEnvironment(environment),
        userStore: UserAPIKeyStore(
            configPaths: MuseQuotaClient.userConfigPaths,
            environmentNames: MuseQuotaClient.userEnvironmentNames,
            files: FakeFiles(files),
            environment: FakeEnvironment(environment),
            makeError: { MuseUsageError($0) }
        ),
        quotaMemoryDirectory: { directory }
    )
}

private func okSSEClient(_ sse: String = museQuotaSSEFixture) -> FakeHTTPClient {
    FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(sse.utf8)))
}

/// Variant sharing one `FakeFiles` so tests can assert on file content.
private func makeQuotaClientWithFiles(
    http: any HTTPClient,
    keychainValue: String? = nil,
    environment: [String: String] = [:],
    files: FakeFiles,
    memoryDirectory: URL? = nil
) -> MuseQuotaClient {
    let directory = memoryDirectory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("muse-quota-memory-\(UUID().uuidString)")
    return MuseQuotaClient(
        http: http,
        keychain: FakeKeychain(keychainValue),
        environment: FakeEnvironment(environment),
        userStore: UserAPIKeyStore(
            configPaths: MuseQuotaClient.userConfigPaths,
            environmentNames: MuseQuotaClient.userEnvironmentNames,
            files: files,
            environment: FakeEnvironment(environment),
            makeError: { MuseUsageError($0) }
        ),
        quotaMemoryDirectory: { directory }
    )
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

    func testParseKeyPayloadMapsTierNameAndMeters() throws {
        let usage = try MuseQuotaClient.parseKeyPayload(Data(museKeyFixture.utf8))

        XCTAssertEqual(usage.tier, "tier-999")
        XCTAssertEqual(usage.planDisplayName, "Muse Code Test Usage")
        XCTAssertEqual(
            MuseQuotaClient.planName(tier: usage.planDisplayName), "Test Usage")
        XCTAssertEqual(usage.windowUsedPercent, 7)
        XCTAssertEqual(usage.weeklyUsedPercent, 13)
        XCTAssertEqual(
            usage.windowResetsAt, Date(timeIntervalSince1970: 1_788_858_956))
        XCTAssertEqual(
            usage.weeklyResetsAt, Date(timeIntervalSince1970: 1_789_344_000))
        XCTAssertEqual(usage.windowDurationMinutes, 300)
    }

    func testParseKeyPayloadRequiresAPercent() {
        for body in ["{}", #"{"subs_usage":{"window":{},"weekly":{}}}"#] {
            XCTAssertThrowsError(
                try MuseQuotaClient.parseKeyPayload(Data(body.utf8))
            ) { error in
                XCTAssertEqual(error as? MuseQuotaError, .invalidResponse)
            }
        }
    }

    func testFetchKeyQuotaPostsToKeyEndpoint() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: Data(museKeyFixture.utf8)))
        let client = makeQuotaClient(http: http, keychainValue: museKeychainFixture)

        let usage = try await client.fetchKeyQuota(oauthToken: "oauth-token")

        XCTAssertEqual(usage.planDisplayName, "Muse Code Test Usage")
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, MuseQuotaClient.keyURL)
        let auth = try XCTUnwrap(request.headers["Authorization"])
        XCTAssertTrue(auth.hasPrefix("Bearer ") && auth.hasSuffix("oauth-token"))
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }

    func testFetchKeyQuotaUnauthorized() async {
        let client = makeQuotaClient(
            http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())),
            keychainValue: museKeychainFixture)

        do {
            _ = try await client.fetchKeyQuota(oauthToken: "expired")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? MuseQuotaError, .unauthorized)
        }
    }

    func testOAuthTokenReadsAccessTokenField() throws {
        let client = makeQuotaClient(http: okSSEClient(), keychainValue: museKeychainFixture)

        XCTAssertEqual(try client.oauthToken(), "ignored-access")
    }

    func testOAuthTokenNilWithoutAccessToken() throws {
        let client = makeQuotaClient(
            http: okSSEClient(), keychainValue: #"{"api_key":"only-key"}"#)

        XCTAssertNil(try client.oauthToken())
    }

    func testOAuthOwnedRoundTripPreservesAPIKey() throws {
        let path = MuseQuotaClient.userConfigPaths[0]
        let files = FakeFiles([path: #"{"apiKey":"k"}"#])
        let client = makeQuotaClientWithFiles(http: okSSEClient(), files: files)

        XCTAssertTrue(client.saveOAuthTokenToOwnedFile("o"))
        XCTAssertEqual(client.oauthTokenFromOwnedFile(), "o")
        XCTAssertEqual(try client.apiKey(), "k", "saved API key survives the merge")
        let raw = try XCTUnwrap(files.files[path])
        XCTAssertTrue(raw.contains("\"apiKey\"") && raw.contains("\"oauthToken\""))
    }

    func testOAuthOwnedRefusesMalformed() throws {
        let path = MuseQuotaClient.userConfigPaths[0]
        let files = FakeFiles([path: "raw-key"])
        let client = makeQuotaClientWithFiles(http: okSSEClient(), files: files)

        XCTAssertFalse(client.saveOAuthTokenToOwnedFile("o"))
        XCTAssertNil(client.oauthTokenFromOwnedFile())
        XCTAssertEqual(files.files[path], "raw-key", "raw-string key file must not be clobbered")
    }

    func testOAuthTokenPrefersOwnedOverKeychain() throws {
        let files = FakeFiles(
            [MuseQuotaClient.userConfigPaths[0]: #"{"oauthToken":"stale"}"#])
        let client = makeQuotaClientWithFiles(
            http: okSSEClient(), keychainValue: museKeychainFixture, files: files)

        XCTAssertEqual(try client.oauthToken(), "stale")
    }

    func testRefreshOAuthTokenRebootstrapsFromKeychain() throws {
        let path = MuseQuotaClient.userConfigPaths[0]
        let files = FakeFiles([path: #"{"oauthToken":"stale"}"#])
        var client = makeQuotaClientWithFiles(
            http: okSSEClient(), keychainValue: museKeychainFixture, files: files)

        XCTAssertEqual(try client.refreshOAuthToken(), "ignored-access")
        XCTAssertEqual(client.oauthTokenFromOwnedFile(), "ignored-access")

        // Memoized too: with the file cleared and the keychain emptied, the
        // fresh token still resolves without a new read.
        client.clearOAuthTokenOwnedFile()
        client.keychain = FakeKeychain(nil)
        XCTAssertEqual(try client.oauthToken(), "ignored-access")
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
        // The keychain fixture carries OAuth, so the refresh tries the
        // account endpoint first (the canned SSE body is not key JSON, so
        // it falls back) and then the probe.
        XCTAssertTrue(http.requests.count == 2, "account attempt plus one probe per refresh")
    }

    @MainActor
    func testRefreshUsesAccountEndpointFirst() async throws {
        let http = RoutingHTTPClient { req in
            if req.url == MuseQuotaClient.keyURL {
                return HTTPResponse(
                    statusCode: 200, headers: [:], body: Data(museKeyFixture.utf8))
            }
            XCTFail("probe must not run after a successful account call")
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
            quotaClient: makeQuotaClient(http: http, keychainValue: museKeychainFixture),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.used, 7)
        XCTAssertEqual(museProgress(snapshot.lines, "Weekly")?.used, 13)
        XCTAssertEqual(snapshot.plan, "Test Usage", "server display name, prefix trimmed")
        XCTAssertEqual(http.requests.count, 1, "no probe after a successful account call")
    }

    @MainActor
    func testRefreshFallsBackToProbeWhenAccountRejected() async throws {
        let http = RoutingHTTPClient { req in
            if req.url == MuseQuotaClient.keyURL {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200, headers: [:], body: Data(museQuotaSSEFixture.utf8))
        }
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
        XCTAssertEqual(snapshot.plan, "tier-123", "probe tier passthrough after account 401")
        XCTAssertEqual(http.requests.count, 2)
    }

    @MainActor
    func testRefreshStaleOwnedRetriesFromKeychain() async throws {
        let path = MuseQuotaClient.userConfigPaths[0]
        let http = RoutingHTTPClient { req in
            guard req.url == MuseQuotaClient.keyURL else {
                XCTFail("probe must not run after a successful retry")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            let auth = req.headers["Authorization"] ?? ""
            if auth.hasSuffix("stale-oauth") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertTrue(
                auth.hasSuffix("fresh-oauth"), "retry must use the rebootstrapped token")
            return HTTPResponse(
                statusCode: 200, headers: [:], body: Data(museKeyFixture.utf8))
        }
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(
                http: http,
                keychainValue: #"{"access_token":"fresh-oauth","api_key":"kc-key"}"#,
                files: [path: #"{"oauthToken":"stale-oauth"}"#]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.used, 7)
        XCTAssertEqual(museProgress(snapshot.lines, "Weekly")?.used, 13)
        XCTAssertEqual(snapshot.plan, "Test Usage")
        XCTAssertEqual(http.requests.count, 2, "stale attempt plus one keychain retry")
    }

    @MainActor
    func testRefreshExhaustedFallsBackToProbe() async throws {
        let path = MuseQuotaClient.userConfigPaths[0]
        let http = RoutingHTTPClient { req in
            if req.url == MuseQuotaClient.keyURL {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200, headers: [:], body: Data(museQuotaSSEFixture.utf8))
        }
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(
                http: http,
                keychainValue: #"{"api_key":"kc-key"}"#,
                files: [path: #"{"oauthToken":"stale-oauth"}"#]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        // The refresh finds no token anywhere (no request), so the probe
        // decides: two requests total, probe meters, tier passthrough.
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.used, 42)
        XCTAssertEqual(museProgress(snapshot.lines, "Weekly")?.used, 49)
        XCTAssertEqual(snapshot.plan, "tier-123")
        XCTAssertEqual(http.requests.count, 2)
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

final class MuseQuotaMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-quota-memory-test-\(UUID().uuidString)")
    }

    func testStateDirectoryHonorsXDG() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(
            MuseQuotaMemory.stateDirectory(
                environment: ["XDG_STATE_HOME": "/tmp/xdg"], home: home).path,
            "/tmp/xdg/openusage")
        XCTAssertEqual(
            MuseQuotaMemory.stateDirectory(environment: [:], home: home).path,
            "/Users/tester/.local/state/openusage")
        XCTAssertEqual(
            MuseQuotaMemory.stateDirectory(
                environment: ["XDG_STATE_HOME": "   "], home: home).path,
            "/Users/tester/.local/state/openusage")
    }

    func testSuccessfulProbePersistsAttributionMemory() async throws {
        let directory = tempDir()
        let client = makeQuotaClient(
            http: okSSEClient(), keychainValue: museKeychainFixture,
            memoryDirectory: directory)
        _ = try await client.fetchQuota(apiKey: "k")

        let memory = MuseQuotaMemory.load(from: MuseQuotaMemory.fileURL(in: directory))
        XCTAssertEqual(memory?.weeklyResetUnix, 1_789_344_000)
        XCTAssertEqual(memory?.windowResetUnix, 1_788_858_956)
        XCTAssertEqual(memory?.weeklyUsed, 49)
        XCTAssertEqual(memory?.windowUsed, 42)
        XCTAssertEqual(memory?.tier, "tier-123")
    }

    func testBlockedWindowLabelSessionWhenResetFarFromWeekly() {
        // The reported bug: a 4h-out reset against a 6d-out weekly memory is
        // the session window, not the week.
        let memory = MuseQuotaMemory(
            weeklyResetUnix: 1_800_518_400, windowResetUnix: 1_800_014_940)
        XCTAssertEqual(
            MuseQuotaClient.blockedWindowLabel(
                resetsAt: Date(timeIntervalSince1970: 1_800_014_940),
                now: now, memory: memory),
            "Session")
    }

    func testBlockedWindowLabelWeeklyWhenResetNearWeekly() {
        let memory = MuseQuotaMemory(weeklyResetUnix: 1_800_518_400, windowResetUnix: nil)
        XCTAssertEqual(
            MuseQuotaClient.blockedWindowLabel(
                resetsAt: Date(timeIntervalSince1970: 1_800_516_000),
                now: now, memory: memory),
            "Weekly")
    }

    func testBlockedWindowLabelWeeklyWithoutOrWithExpiredMemory() {
        XCTAssertEqual(
            MuseQuotaClient.blockedWindowLabel(resetsAt: now, now: now, memory: nil),
            "Weekly")
        XCTAssertEqual(
            MuseQuotaClient.blockedWindowLabel(resetsAt: nil, now: now, memory: nil),
            "Weekly")
        let expired = MuseQuotaMemory(weeklyResetUnix: 1_799_000_000, windowResetUnix: nil)
        XCTAssertEqual(
            MuseQuotaClient.blockedWindowLabel(resetsAt: now, now: now, memory: expired),
            "Weekly")
    }

    func testBlockedQuotaLineUsesSessionPeriodForSession() {
        let line = MuseQuotaClient.blockedQuotaLine(resetsAt: now, label: "Session")
        guard case .progress(let label, let used, _, _, _, _, _) = line else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 100)
    }

    @MainActor
    func testRefresh429WithSessionMemoryShowsSessionBlocked() async {
        let frozenNow = now
        let sessionReset = Date(timeIntervalSince1970: 1_800_014_940) // ~4h out
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 429, headers: [:],
            body: Data(
                #"{"error":{"code":"rate_limit_exceeded","message":"Subscription quota exhausted","resets_at":1800014940}}"#.utf8)))
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(http: http, keychainValue: museKeychainFixture),
            now: { frozenNow }
        )
        // Seed the shared memory as a prior successful poll would have.
        MuseQuotaMemory(
            weeklyUsed: 49, weeklyResetUnix: 1_800_518_400,
            windowUsed: 42, windowResetUnix: 1_788_858_956,
            tier: "tier-123", observedAtUnix: 1_799_000_000
        ).save(to: MuseQuotaMemory.fileURL(
            in: provider.quotaClient.quotaMemoryDirectory()))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.used, 100)
        XCTAssertEqual(museProgress(snapshot.lines, "Session")?.resetsAt, sessionReset)
        XCTAssertNil(museProgress(snapshot.lines, "Weekly"), "no fabricated weekly block")
    }

    @MainActor
    func testRefresh429WithoutMemoryKeepsLegacyWeekly() async {
        let frozenNow = now
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 429, headers: [:],
            body: Data(
                #"{"error":{"code":"rate_limit_exceeded","message":"Subscription quota exhausted","resets_at":1800014940}}"#.utf8)))
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(), environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent-muse-quota") },
                incrementalScanner: IncrementalJSONLScanner()),
            quotaClient: makeQuotaClient(http: http, keychainValue: museKeychainFixture),
            now: { frozenNow }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(museProgress(snapshot.lines, "Weekly")?.used, 100)
        XCTAssertNil(museProgress(snapshot.lines, "Session"))
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
