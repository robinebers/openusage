import XCTest
@testable import OpenUsage

final class CommandCodeAuthStoreTests: XCTestCase {
    func testCredentialSourcesAndErrors() throws {
        let env = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialsPath: #"{"apiKey":"file"}"#]),
            environment: FakeEnvironment([CommandCodeAuthStore.environmentName: "  env-key\n"])
        )
        let file = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialsPath: #"{"apiKey":" file-key ","userId":"private"}"#]),
            environment: FakeEnvironment([CommandCodeAuthStore.environmentName: " "])
        )
        let malformed = CommandCodeAuthStore(
            files: FakeFiles([CommandCodeAuthStore.credentialsPath: #"{"apiKey":" "}"#]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(try env.loadAuth()?.apiKey, "env-key")
        XCTAssertEqual(try file.loadAuth()?.apiKey, "file-key")
        XCTAssertNil(try CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment()).loadAuth())
        XCTAssertThrowsError(try malformed.loadAuth()) {
            XCTAssertEqual($0 as? CommandCodeAuthError, .invalidCredentials)
        }
    }

    func testUnreadableCredentialFileIsReported() {
        let store = CommandCodeAuthStore(
            files: UnreadableFiles(present: [CommandCodeAuthStore.credentialsPath]),
            environment: FakeEnvironment()
        )
        XCTAssertThrowsError(try store.loadAuth()) {
            XCTAssertEqual($0 as? CommandCodeAuthError, .credentialsUnreadable)
        }
    }
}

final class CommandCodeUsageClientTests: XCTestCase {
    func testEndpointsAuthorizationAndQueries() async throws {
        let http = RoutingHTTPClient { _ in .ok(Data("{}".utf8)) }
        let client = CommandCodeUsageClient(http: http)

        _ = try await client.fetchWhoami(apiKey: "secret")
        _ = try await client.fetchCredits(apiKey: "secret", organizationID: " org-42 ")
        _ = try await client.fetchSubscription(apiKey: "secret", organizationID: "org-42")
        _ = try await client.fetchUsageSummary(
            apiKey: "secret",
            organizationID: "org-42",
            since: Fixtures.periodStart
        )

        XCTAssertEqual(http.requests.map(\.url.path), [
            "/alpha/whoami", "/alpha/billing/credits",
            "/alpha/billing/subscriptions", "/alpha/usage/summary"
        ])
        XCTAssertTrue(http.requests.allSatisfy {
            $0.method == "GET" && $0.headers["Authorization"] == "Bearer secret" && $0.timeout == 15
        })
        XCTAssertEqual(query(http.requests[1].url), ["orgId": "org-42"])
        XCTAssertEqual(query(http.requests[3].url), ["orgId": "org-42", "since": Fixtures.periodStart])
    }
}

final class CommandCodeUsageMapperTests: XCTestCase {
    func testAccountAndSubscriptionMapping() throws {
        XCTAssertNil(try CommandCodeUsageMapper.organizationID(from: Fixtures.whoami()))
        XCTAssertEqual(try CommandCodeUsageMapper.organizationID(from: Fixtures.whoami(orgID: " org-42 ")), "org-42")
        let context = try XCTUnwrap(CommandCodeUsageMapper.subscriptionContext(from: Fixtures.subscription()))
        XCTAssertEqual(context.planName, "Go")
        XCTAssertEqual(context.currentPeriodStart, Fixtures.periodStart)
        XCTAssertGreaterThan(context.periodDurationMs, 0)
        XCTAssertNil(try CommandCodeUsageMapper.subscriptionContext(
            from: Data(#"{"success":true,"data":{"status":"canceled","planId":"individual-go"}}"#.utf8)
        ))
    }

    func testMapsSubscriptionMetersAndBalanceOnlyAccount() throws {
        let subscription = try XCTUnwrap(CommandCodeUsageMapper.subscriptionContext(from: Fixtures.subscription()))
        let mapped = try CommandCodeUsageMapper.map(
            creditsBody: Fixtures.credits(), summaryBody: Fixtures.summary(), subscription: subscription
        )
        XCTAssertEqual(mapped.plan, "Go")
        XCTAssertEqual(mapped.lines.map(\.label), ["5-Hour", "Weekly", "Monthly", "Balance", "Requests"])
        assertProgress(mapped.lines[0], used: 1.25, limit: 3, resetMs: Fixtures.fiveHourResetMs)
        assertProgress(mapped.lines[1], used: 2.5, limit: 6, resetMs: Fixtures.weeklyResetMs)
        assertProgress(
            mapped.lines[2], used: 1, limit: 10,
            resetMs: Int(subscription.currentPeriodEnd.timeIntervalSince1970 * 1000)
        )
        assertValue(mapped.lines[3], number: 12, kind: .dollars)
        assertValue(mapped.lines[4], number: 109, kind: .count)

        let balanceOnly = try CommandCodeUsageMapper.map(
            creditsBody: Fixtures.balanceOnlyCredits(),
            summaryBody: Fixtures.summary(),
            subscription: nil
        )
        XCTAssertNil(balanceOnly.plan)
        XCTAssertEqual(balanceOnly.lines.map(\.label), ["Balance", "Requests"])
    }

    func testRejectsInvalidResponsesAndFormatsPlanFallbacks() throws {
        let subscription = try XCTUnwrap(CommandCodeUsageMapper.subscriptionContext(from: Fixtures.subscription()))
        XCTAssertThrowsError(try CommandCodeUsageMapper.map(
            creditsBody: Fixtures.credits(fiveHourCap: 0),
            summaryBody: Fixtures.summary(),
            subscription: subscription
        )) {
            XCTAssertEqual($0 as? CommandCodeUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try CommandCodeUsageMapper.organizationID(from: Data(#"{"success":false}"#.utf8)))
        XCTAssertEqual(CommandCodeUsageMapper.planName(for: "individual-pro-annual"), "Pro")
        XCTAssertEqual(CommandCodeUsageMapper.planName(for: "future-plan"), "Future Plan")
    }
}

@MainActor
final class CommandCodeProviderTests: XCTestCase {
    func testMetadataAndSuccessfulRefreshForOrganization() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": return .ok(Fixtures.whoami(orgID: "org-42"))
            case "/alpha/billing/credits": return .ok(Fixtures.credits())
            case "/alpha/billing/subscriptions": return .ok(Fixtures.subscription())
            case "/alpha/usage/summary": return .ok(Fixtures.summary())
            default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(http: http)
        let snapshot = await provider.refresh()

        XCTAssertEqual(provider.provider.id, "commandcode")
        XCTAssertEqual(provider.provider.displayName, "Command Code")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), [
            "commandcode.fiveHour", "commandcode.weekly", "commandcode.monthly",
            "commandcode.balance", "commandcode.requests"
        ])
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.lines.map(\.label), ["5-Hour", "Weekly", "Monthly", "Balance", "Requests"])
        for request in http.requests.dropFirst() {
            XCTAssertEqual(query(request.url)["orgId"], "org-42")
        }
    }

    func testAuthenticationFailuresStayDistinct() async {
        let noAuthHTTP = RoutingHTTPClient { _ in
            XCTFail("API must not be called without credentials")
            return .ok(Data())
        }
        let noAuth = CommandCodeProvider(
            authStore: CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: CommandCodeUsageClient(http: noAuthHTTP)
        )
        let unauthorized = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let forbidden = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }

        let noAuthSnapshot = await noAuth.refresh()
        let unauthorizedSnapshot = await makeProvider(http: unauthorized).refresh()
        let forbiddenSnapshot = await makeProvider(http: forbidden).refresh()

        XCTAssertEqual(noAuthSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(unauthorizedSnapshot.errorCategory, .authExpired)
        XCTAssertEqual(forbiddenSnapshot.errorCategory, .http4xx)
        XCTAssertTrue(noAuthHTTP.requests.isEmpty)
    }

    func testRefreshKeepsBalanceAndRequestsWithoutSubscriptionOrCaps() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": return .ok(Fixtures.whoami())
            case "/alpha/billing/credits": return .ok(Fixtures.balanceOnlyCredits())
            case "/alpha/billing/subscriptions": return .ok(Data(#"{"success":true,"data":null}"#.utf8))
            case "/alpha/usage/summary": return .ok(Fixtures.summary())
            default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Balance", "Requests"])
        XCTAssertNil(http.requests.last?.url.query)
    }

    private func makeProvider(http: RoutingHTTPClient) -> CommandCodeProvider {
        CommandCodeProvider(
            authStore: CommandCodeAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment([CommandCodeAuthStore.environmentName: "env-key"])
            ),
            usageClient: CommandCodeUsageClient(http: http)
        )
    }
}

private enum Fixtures {
    static let periodStart = "2026-07-21T18:54:40.000Z"
    static let periodEnd = "2026-08-21T18:54:40.000Z"
    static let fiveHourResetMs = 1_784_758_892_394
    static let weeklyResetMs = 1_785_265_196_770

    static func whoami(orgID: String? = nil) -> Data {
        let org = orgID.map { #", "org":{"id":"\#($0)"}"# } ?? ""
        return Data(#"{"success":true,"user":{"id":"private"}\#(org)}"#.utf8)
    }

    static func credits(fiveHourCap: Double = 3) -> Data {
        Data(#"{"credits":{"creditThreshold":5,"monthlyCredits":9,"purchasedCredits":2,"freeCredits":1},"windowLimits":{"limited":true,"fiveHour":{"used":1.25,"cap":\#(fiveHourCap),"exceeded":false,"resetAt":\#(fiveHourResetMs)},"weekly":{"used":2.5,"cap":6,"exceeded":false,"resetAt":\#(weeklyResetMs)}}}"#.utf8)
    }

    static func balanceOnlyCredits() -> Data {
        Data(#"{"credits":{"creditThreshold":5,"monthlyCredits":9,"purchasedCredits":2,"freeCredits":1}}"#.utf8)
    }

    static func subscription() -> Data {
        Data(#"{"success":true,"data":{"status":"active","currentPeriodStart":"\#(periodStart)","currentPeriodEnd":"\#(periodEnd)","planId":"individual-go"}}"#.utf8)
    }

    static func summary() -> Data {
        Data(#"{"totalCount":109,"totalCost":4,"totalMonthlyCredits":1,"totalPurchasedCredits":2,"totalFreeCredits":1}"#.utf8)
    }
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .compactMap { item in item.value.map { (item.name, $0) } })
}

private func assertProgress(_ line: MetricLine, used: Double, limit: Double, resetMs: Int) {
    guard case .progress(_, let actualUsed, let actualLimit, _, let reset, _, _) = line else {
        return XCTFail("Expected progress line")
    }
    XCTAssertEqual(actualUsed, used, accuracy: 0.000_001)
    XCTAssertEqual(actualLimit, limit, accuracy: 0.000_001)
    XCTAssertEqual(Int((reset?.timeIntervalSince1970 ?? -1) * 1000), resetMs)
}

private func assertValue(_ line: MetricLine, number: Double, kind: MetricKind) {
    guard case .values(_, let values, _, _, _, _) = line else { return XCTFail("Expected values line") }
    XCTAssertEqual(values.first?.number, number)
    XCTAssertEqual(values.first?.kind, kind)
}

private extension HTTPResponse {
    static func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}
