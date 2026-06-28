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
    func testMapsPaidPremiumAndChatAsPercentUsed() throws {
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(progress(mapped.lines, "Premium")?.used, 59)
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 5)
        XCTAssertNotNil(progress(mapped.lines, "Premium")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Premium")?.periodDurationMs, CopilotUsageMapper.periodMs)
    }

    func testUnlimitedBucketRendersEmptyMeterWithoutReset() throws {
        var snapshots = makePaidBody()
        var quota = snapshots["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["unlimited": true, "entitlement": 0, "remaining": 0, "quota_id": "chat"]
        snapshots["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: snapshots)

        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 0)
        XCTAssertNil(progress(mapped.lines, "Chat")?.resetsAt)
        XCTAssertNil(progress(mapped.lines, "Chat")?.periodDurationMs)
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

        XCTAssertNil(progress(mapped.lines, "Premium"))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 20)
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
        XCTAssertEqual(snapshot.line(label: "Premium")?.label, "Premium")
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
