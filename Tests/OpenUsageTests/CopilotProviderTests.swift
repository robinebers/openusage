import XCTest
@testable import OpenUsage

final class CopilotAuthStoreTests: XCTestCase {
    func testReadsEditorAppsJSON() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: """
                { "github.com:Iv1.abc123": { "user": "octocat", "oauth_token": "gho_editor" } }
                """
            ]),
            keychain: FakeKeychain()
        )

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_editor")
        XCTAssertEqual(token?.source, .editorApp)
    }

    func testReadsGhHostsOAuthToken() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                github.com:
                    git_protocol: https
                    user: octocat
                    oauth_token: gho_ghconfig
                """
            ]),
            keychain: FakeKeychain()
        )

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_ghconfig")
        XCTAssertEqual(token?.source, .ghConfig)
    }

    func testDecodesGoKeyringWrappedGhKeychainToken() {
        let wrapped = "go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString()
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain(wrapped))

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_keychain")
        XCTAssertEqual(token?.source, .ghKeychain)
    }

    func testEditorConfigWinsOverKeychain() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString())
        )

        XCTAssertEqual(store.loadToken()?.source, .editorApp)
    }

    func testReturnsNilWhenNoCredentials() {
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain())
        XCTAssertNil(store.loadToken())
    }

    func testEditorConfigIgnoresNonGithubDotComHost() {
        // An Enterprise-only editor config must not yield a token for api.github.com; the chain should
        // fall through to the gh keychain (which here holds the real github.com token).
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_enterprise" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_dotcom".utf8).base64EncodedString())
        )

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_dotcom")
        XCTAssertEqual(token?.source, .ghKeychain)
    }

    func testEditorConfigPicksGithubDotComAmongHosts() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_ent" }, "github.com:Iv1.y": { "oauth_token": "gho_dotcom" } }"#
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(store.loadToken()?.value, "gho_dotcom")
    }

    func testYamlValueIgnoresNestedUsersMap() {
        let hosts = """
        github.com:
            users:
                octocat:
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testYamlValueScopesToGithubDotComHost() {
        // A GitHub Enterprise block precedes github.com; the github.com token must win.
        let hosts = """
        ghe.corp.example:
            oauth_token: gho_enterprise
            user: ent
        github.com:
            oauth_token: gho_dotcom
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "oauth_token"), "gho_dotcom")
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testGhConfigPrefersGithubDotComTokenOverEnterprise() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                ghe.corp.example:
                    oauth_token: gho_enterprise
                github.com:
                    oauth_token: gho_dotcom
                """
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(store.loadToken()?.value, "gho_dotcom")
    }
}

final class CopilotUsageMapperTests: XCTestCase {
    func testMapsPaidCreditsAndChatAsPercentUsed() throws {
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 5)
        XCTAssertNotNil(progress(mapped.lines, "Credits")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Credits")?.periodDurationMs, CopilotUsageMapper.periodMs)
    }

    func testSuppressesUnlimitedAndSentinelBuckets() throws {
        // Paid plans report chat/completions as unlimited — both the explicit flag and the `-1`
        // entitlement/remaining sentinel — which carry no real meter and must be suppressed, leaving
        // just Credits.
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["unlimited": true, "entitlement": 0, "remaining": 0, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
    }

    func testEmitsExtraUsageWhenOveragePermitted() throws {
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 36
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), 36)
    }

    func testShowsExtraUsageZeroWhenPermittedButUnused() throws {
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 0
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), 0)
    }

    func testSuppressesExtraUsageWhenNotPermitted() throws {
        // makePaidBody's premium has no overage flag → extra usage is genuinely N/A.
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
    }

    func testIgnoresLegacyLimitedQuotasWhenSnapshotsPresent() throws {
        // A paid response with Credits present and chat/completions unlimited (-1) must NOT fall back to
        // the legacy limited_user_quotas path, even if the payload still carries it — doing so would show
        // free-tier Chat/Completions meters on a paid account alongside Credits.
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["entitlement": -1, "remaining": -1, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota
        body["limited_user_quotas"] = ["chat": 100, "completions": 1000]
        body["monthly_quotas"] = ["chat": 500, "completions": 4000]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNotNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
    }

    func testSuppressesZeroEntitlementPlaceholder() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 100, "quota_id": "premium"],
                "chat": ["entitlement": 1000, "remaining": 800, "percent_remaining": 80, "quota_id": "chat"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 20)
    }

    func testMapsLiveFreeAccountSnapshots() throws {
        // The exact shape a free `individual` account returns today: real chat/completions counts in
        // `quota_snapshots`, a zero-entitlement premium bucket, and `token_based_billing` on every bucket.
        // Credits + Extra Usage suppress (no allotment / overage off); Chat + Completions render.
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_reset_date": "2099-07-01",
            "quota_snapshots": [
                "chat": ["entitlement": 200, "remaining": 182, "percent_remaining": 91.0, "overage_permitted": false, "token_based_billing": true],
                "completions": ["entitlement": 2000, "remaining": 1989, "percent_remaining": 99.4, "overage_permitted": false, "token_based_billing": true],
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 0.0, "overage_permitted": false, "token_based_billing": true]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used ?? -1, 0.6, accuracy: 0.0001)
    }

    func testMapsFreeTierLimitedQuotas() throws {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "limited_user_quotas": ["chat": 250, "completions": 2000],
            "monthly_quotas": ["chat": 500, "completions": 4000],
            "limited_user_reset_date": "2099-02-15"
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 50)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used, 50)
        XCTAssertNotNil(progress(mapped.lines, "Chat")?.resetsAt)
    }

    func testTokenBasedBillingReturnsPlanWithoutMeters() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "quota_id": "premium"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Business")
        XCTAssertTrue(mapped.lines.isEmpty)
    }

    func testThrowsQuotaUnavailableWhenEmpty() {
        XCTAssertThrowsError(try CopilotUsageMapper.map(body: ["copilot_plan": "pro"])) { error in
            XCTAssertEqual(error as? CopilotUsageError, .quotaUnavailable)
        }
    }
}

@MainActor
final class CopilotProviderTests: XCTestCase {
    func testNotLoggedInWhenNoToken() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testTokenInvalidOn401() async {
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testMapsLinesAndSendsTokenHeaderOnSuccess() async throws {
        let http = FakeHTTPClient(response: ok(makePaidBody()))
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Credits")?.label, "Credits")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "token gho_editor")
    }

    func testTokenBasedBillingShowsPlanWithoutError() async {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["entitlement": 0, "remaining": 0]]
        ]
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(body)))
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
    }

    private func editorTokenStore() -> CopilotAuthStore {
        CopilotAuthStore(
            files: FakeFiles([CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#]),
            keychain: FakeKeychain()
        )
    }
}

// MARK: - Helpers

private func makePaidBody() -> [String: Any] {
    [
        "copilot_plan": "pro",
        "quota_reset_date": "2099-01-15T00:00:00Z",
        "quota_snapshots": [
            "premium_interactions": ["entitlement": 300, "remaining": 123, "percent_remaining": 41, "quota_id": "premium"],
            "chat": ["entitlement": 1000, "remaining": 950, "percent_remaining": 95, "quota_id": "chat"]
        ]
    ]
}

private func ok(_ body: [String: Any]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func countValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first?.number
}
