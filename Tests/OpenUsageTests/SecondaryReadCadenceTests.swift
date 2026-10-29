import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class SecondaryReadCadenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexReadsResetCreditsHourly() async throws {
        let counts = try await hourOfRefreshes(.codex, credential: .oauth(OAuthTokens(accessToken: "token"))) { _ in
            Self.ok(#"{"rate_limit":{}}"#)
        }
        XCTAssertEqual(counts.perHour[CodexUsageClient.usageURL.path], 12)
        XCTAssertEqual(counts.perHour[CodexUsageClient.resetCreditsURL.path], 1)
        XCTAssertEqual(counts.total, 13)
        XCTAssertEqual(counts.nextHour[CodexUsageClient.resetCreditsURL.path], 1, "read again once the hour is up")
    }

    func testTheLiveResetCountWinsOverTheHourlyListAndKeepsItsExpiriesOnlyWhileTheyAgree() async throws {
        let expiry = OpenUsageISO8601.string(from: start.addingTimeInterval(3 * 86_400))
        let cases: [(name: String, dedicated: Int, live: Int, expiries: Int)] = [
            ("spent outside OpenUsage", 1, 0, 0),
            ("granted since the hourly read", 0, 1, 0),
            ("unchanged", 1, 1, 1)
        ]
        for entry in cases {
            let account = Account(kind: .codex, label: "Work")
            let vault = InMemoryCredentialVault()
            try vault.save(.oauth(OAuthTokens(accessToken: "token")), for: account.id)
            let live = TestSwitch(entry.dedicated)
            let http = RoutingHTTPClient { request in
                switch request.url {
                case CodexUsageClient.resetCreditsURL:
                    let credits = entry.dedicated > 0 ? #"{"id":"RateLimitResetCredit_1","status":"available","expires_at":"\#(expiry)"}"# : ""
                    return Self.ok(#"{"available_count":\#(entry.dedicated),"credits":[\#(credits)]}"#)
                default:
                    return Self.ok(#"{"rate_limit":{},"rate_limit_reset_credits":{"available_count":\#(live.value)}}"#)
                }
            }
            let clock = TestClock(start)
            let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
            _ = await runtime.refresh()
            live.value = entry.live
            clock.set(start.addingTimeInterval(RefreshSetting.interval))
            let snapshot = try await runtime.refresh().get()

            guard case .values(_, let values, let expiries)? = snapshot.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
                return XCTFail("\(entry.name): no resets row")
            }
            XCTAssertEqual(values, [MetricValue(number: Double(entry.live), kind: .count, label: "available")], entry.name)
            XCTAssertEqual(expiries.count, entry.expiries, entry.name)
            XCTAssertEqual(http.requests.count { $0.url == CodexUsageClient.resetCreditsURL }, 1, "\(entry.name): the list is read once an hour")
        }
    }

    func testGrokReadsThePlanHourly() async throws {
        let credits = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-30T21:36:52+00:00","end":"2026-07-07T21:36:52+00:00"},"creditUsagePercent":40}}"#
        let counts = try await hourOfRefreshes(.grok, credential: .oauth(OAuthTokens(accessToken: "token"))) { request in
            request.url == GrokUsageClient.settingsURL ? Self.ok(#"{"subscription_tier_display":"SuperGrok"}"#) : Self.ok(credits)
        }
        XCTAssertEqual(counts.perHour[GrokUsageClient.settingsURL.path], 1)
        XCTAssertEqual(counts.total, 13)
        XCTAssertEqual(counts.lastPlan, "SuperGrok", "the hourly plan still shows on every pass")
    }

    func testOllamaReadsThePlanHourly() async throws {
        let counts = try await hourOfRefreshes(.ollama, credential: .apiKey("key")) { _ in Self.ok("{}") }
        XCTAssertEqual(counts.perHour[OllamaUsageClient.balancePath], 12)
        XCTAssertEqual(counts.perHour[OllamaUsageClient.accountPath], 1)
        XCTAssertEqual(counts.total, 13)
    }

    func testZAIReadsTheSubscriptionHourly() async throws {
        let counts = try await hourOfRefreshes(.zai, credential: .apiKey("key")) { _ in Self.ok("{}") }
        XCTAssertEqual(counts.perHour[ZAIUsageClient.quotaURL.path], 12)
        XCTAssertEqual(counts.perHour[ZAIUsageClient.subscriptionURL.path], 1)
        XCTAssertEqual(counts.total, 13)
    }

    func testCursorReadsThePlanHourly() async throws {
        let token = "e30." + Data(#"{"sub":"auth0|user_fake"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "") + ".sig"
        let counts = try await hourOfRefreshes(.cursor, credential: .oauth(OAuthTokens(
            accessToken: token, refreshToken: "refresh", expiresAt: start.addingTimeInterval(30 * 86_400)
        ))) { _ in Self.ok(#"{"planUsage":{"limit":40000,"remaining":30000,"totalPercentUsed":25},"enabled":true}"#) }
        XCTAssertEqual(counts.perHour[CursorUsageClient.usageURL.path], 12)
        XCTAssertEqual(counts.perHour[CursorUsageClient.planURL.path], 1)
    }

    func testCopilotReadsOrgBillingHourlyWithAnAdminToken() async throws {
        let org = CopilotUsageClient.orgCreditsURL(org: "acme")
        let counts = try await hourOfRefreshes(.copilot, credential: .oauth(OAuthTokens(
            accessToken: "token", extras: [OAuthTokens.adminTokenKey: "admin"]
        ))) { request in
            request.url == org
                ? Self.ok(#"{"usageItems":[{"product":"Copilot","grossQuantity":100,"netAmount":1.0}]}"#)
                : Self.ok(#"{"token_based_billing":true,"organization_login_list":["acme"]}"#)
        }
        XCTAssertEqual(counts.perHour[org.path], 1)
        XCTAssertEqual(counts.total, 13)
        XCTAssertEqual(counts.nextHour[org.path], 1, "read again once the hour is up")
    }

    func testAntigravityReadsCodeAssistHourly() async throws {
        let counts = try await hourOfRefreshes(.antigravity, credential: .oauth(OAuthTokens(accessToken: "token"))) { request in
            request.url.path.hasSuffix(AntigravityUsageClient.loadCodeAssistPath)
                ? Self.ok(#"{"cloudaicompanionProject":"p"}"#)
                : Self.ok(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#)
        }
        XCTAssertEqual(counts.perHour.filter { $0.key.hasSuffix(AntigravityUsageClient.loadCodeAssistPath) }.values.reduce(0, +), 1)
    }

    func testAForcedRefreshAsksTheHourlyReadsAgain() async throws {
        let codex = try await passThenForcedRefresh(.codex) { _ in Self.ok(#"{"rate_limit":{}}"#) }
        XCTAssertEqual(codex.map { $0[CodexUsageClient.resetCreditsURL.path] }, [1, 2])

        let ollama = try await passThenForcedRefresh(.ollama, credential: .apiKey("key")) { _ in Self.ok("{}") }
        XCTAssertEqual(ollama.map { $0[OllamaUsageClient.accountPath] }, [1, 2])
    }

    private func passThenForcedRefresh(
        _ kind: ProviderKind,
        credential: AccountCredential = .oauth(OAuthTokens(accessToken: "token")),
        handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) async throws -> [[String: Int]] {
        let account = Account(kind: kind, label: kind.displayName)
        let vault = InMemoryCredentialVault()
        try vault.save(credential, for: account.id)
        let http = RoutingHTTPClient { handler($0) }
        let clock = TestClock(start)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        func counts() -> [String: Int] {
            http.requests.reduce(into: [:]) { $0[$1.url.path, default: 0] += 1 }
        }
        await store.refreshAll()
        clock.set(start.addingTimeInterval(RefreshSetting.interval))
        await store.refreshAll()
        let scheduled = counts()
        clock.set(start.addingTimeInterval(RefreshSetting.interval + 60))
        await store.refreshAll(force: true)
        return [scheduled, counts()]
    }

    private struct Counts {
        var perHour: [String: Int]
        var total: Int
        var nextHour: [String: Int]
        var lastPlan: String?
    }

    private func hourOfRefreshes(
        _ kind: ProviderKind,
        credential: AccountCredential,
        handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) async throws -> Counts {
        let account = Account(kind: kind, label: kind.displayName)
        let vault = InMemoryCredentialVault()
        try vault.save(credential, for: account.id)
        let http = RoutingHTTPClient { handler($0) }
        let clock = TestClock(start)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        var lastPlan: String?
        for pass in 0..<12 {
            clock.set(start.addingTimeInterval(TimeInterval(pass) * RefreshSetting.interval))
            lastPlan = (try? await runtime.refresh().get())?.plan
        }
        let hour = http.requests
        clock.set(start.addingTimeInterval(RefreshSetting.secondaryReadInterval))
        _ = await runtime.refresh()
        let next = http.requests.dropFirst(hour.count)
        func byPath(_ requests: some Sequence<HTTPRequest>) -> [String: Int] {
            requests.reduce(into: [:]) { $0[$1.url.path, default: 0] += 1 }
        }
        return Counts(perHour: byPath(hour), total: hour.count, nextHour: byPath(next), lastPlan: lastPlan)
    }

    nonisolated private static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}
