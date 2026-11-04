import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class MuseProviderTests: XCTestCase {
    private static let inferenceKey = "LLM|1234|SYNTHETIC-inference-key"
    private static let start = Date(timeIntervalSince1970: 1_793_790_000)
    private static let sessionReset = start.addingTimeInterval(3 * 3600)
    private static let weeklyReset = start.addingTimeInterval(3 * 86400)
    private static let active = body(usage: """
        {"window":{"used_percent":42,"resets_at":\(Int(sessionReset.timeIntervalSince1970)),"window_duration_mins":300},\
        "weekly":{"used_percent":18,"resets_at":\(Int(weeklyReset.timeIntervalSince1970))}}
        """)

    private static func body(subscribed: Bool = true, usage: String? = nil) -> String {
        let usageField = usage.map { #","subs_usage":\#($0)"# } ?? ""
        return #"{"api_key":"\#(inferenceKey)","user_email":"muse@example.com","is_subs_active":\#(subscribed),"subs_tier_name":"Power Usage"\#(usageField)}"#
    }

    private static func response(_ status: Int, _ body: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
    }

    private struct Harness {
        let runtime: AccountProviderRuntime
        let vault: InMemoryCredentialVault
        let http: RoutingHTTPClient
        let clock: TestClock
        let answer: TestSwitch<HTTPResponse>
    }

    private func harness(_ first: HTTPResponse) throws -> Harness {
        let account = Account(kind: .muse, label: "muse@example.com")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "dca:token")), for: account.id)
        let answer = TestSwitch(first)
        let http = RoutingHTTPClient { _ in answer.value }
        let clock = TestClock(Self.start)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        return Harness(runtime: runtime, vault: vault, http: http, clock: clock, answer: answer)
    }

    func testReadsThePlanSessionAndWeeklyWithOneKeyRead() async throws {
        let harness = try harness(Self.response(200, Self.active))

        let snapshot = try await harness.runtime.refresh().get()

        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertEqual(snapshot.lines, [
            .percent("Session", 42, resetsAt: Self.sessionReset, periodMs: MetricPeriod.sessionMs),
            .percent("Weekly", 18, resetsAt: Self.weeklyReset, periodMs: MetricPeriod.weekMs)
        ])
        XCTAssertEqual(harness.http.requests.count, 1)
        let request = try XCTUnwrap(harness.http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, MuseUsageClient.keyURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer dca:token")
        XCTAssertEqual(request.headers["x-api-version"], "1.0.0")
        XCTAssertEqual(request.body.map { String(decoding: $0, as: UTF8.self) }, #"{"onboard":false}"#)
        XCTAssertEqual(harness.runtime.widgetDescriptors.map(\.key), ["session", "weekly"])
    }

    func testAWindowMuseLeavesOutKeepsItsLastKnownValue() async throws {
        let harness = try harness(Self.response(200, Self.active))
        let reported = try await harness.runtime.refresh().get().lines

        harness.answer.value = Self.response(200, Self.body())
        let idle = try await harness.runtime.refresh().get().lines
        XCTAssertEqual(idle, reported, "an idle window is not 0%")

        let relaunched = try self.harness(Self.response(200, Self.body()))
        relaunched.runtime.restore(ProviderSnapshot(provider: relaunched.runtime.provider, plan: "Power Usage", lines: reported))
        let restored = try await relaunched.runtime.refresh().get().lines
        XCTAssertEqual(restored, reported, "the saved values carry over a relaunch")

        harness.clock.set(Self.sessionReset.addingTimeInterval(60))
        let afterReset = try await harness.runtime.refresh().get().lines
        XCTAssertEqual(afterReset, [
            .percent("Session", 0, periodMs: MetricPeriod.sessionMs),
            .percent("Weekly", 18, resetsAt: Self.weeklyReset, periodMs: MetricPeriod.weekMs)
        ], "a kept window past its reset has reset")

        let partial = try self.harness(Self.response(200, Self.active))
        _ = try await partial.runtime.refresh().get()
        partial.answer.value = Self.response(200, Self.body(usage: #"{"weekly":{"used_percent":20}}"#))
        let weeklyOnly = try await partial.runtime.refresh().get().lines
        XCTAssertEqual(weeklyOnly, [
            .percent("Session", 0, periodMs: MetricPeriod.sessionMs),
            .percent("Weekly", 20, periodMs: MetricPeriod.weekMs)
        ], "a reported usage keeps nothing it left out")
    }

    func testAPlanNotUsedYetShowsSessionAndWeeklyAtZero() async throws {
        let harness = try harness(Self.response(200, Self.body()))

        let snapshot = try await harness.runtime.refresh().get()

        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertEqual(snapshot.lines, [
            .percent("Session", 0, periodMs: MetricPeriod.sessionMs),
            .percent("Weekly", 0, periodMs: MetricPeriod.weekMs)
        ], "Muse reports no usage before the first prompt")
    }

    func testUsageOverTheLimitIsKept() async throws {
        let harness = try harness(Self.response(200, Self.body(usage: #"{"weekly":{"used_percent":130.5,"resets_at":1794000000}}"#)))

        let lines = try await harness.runtime.refresh().get().lines

        XCTAssertEqual(lines.last, .percent("Weekly", 130.5, resetsAt: Date(timeIntervalSince1970: 1_794_000_000), periodMs: MetricPeriod.weekMs))
    }

    func testAnAccountWithoutASubscriptionSaysSo() async throws {
        let harness = try harness(Self.response(200, Self.body(subscribed: false)))

        let failure = await harness.runtime.refresh()

        XCTAssertEqual(failure.failure?.message, "No Muse Code subscription on this account.")
    }

    func testARefusedSignInAsksToSignInAgain() async throws {
        let harness = try harness(Self.response(401, #"{"error":"unauthorized"}"#))

        let failure = await harness.runtime.refresh()

        XCTAssertEqual(failure.failure?.message, ProviderError.signInExpired(.muse).localizedDescription)
        XCTAssertEqual(failure.failure?.kind, .refused)
    }

    func testARateLimitWaitsAsLongAsMuseAsks() async throws {
        let harness = try harness(Self.response(429, "", headers: ["retry-after": "120"]))

        let failure = await harness.runtime.refresh()

        XCTAssertEqual(failure.failure?.kind, .rateLimited(retryAfter: 120))
    }

    func testTheInferenceKeyNeverReachesStorageOrLogs() async throws {
        let harness = try harness(Self.response(200, Self.active))
        let snapshot = try await harness.runtime.refresh().get()

        let saved = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(saved.contains("SYNTHETIC-inference-key"), "the cached snapshot")
        XCTAssertEqual(try harness.vault.load(harness.runtime.account.id), .oauth(OAuthTokens(accessToken: "dca:token")))
        let decoded = try await MuseUsageClient(http: harness.http).account(token: "dca:token")
        XCTAssertFalse(String(reflecting: decoded).contains("SYNTHETIC-inference-key"), "the decoded response")

        for unreadable in [
            Self.response(200, #"{"api_key":"\#(Self.inferenceKey)","is_subs_active":"yes"}"#),
            Self.response(500, Self.active),
            Self.response(429, Self.active)
        ] {
            harness.answer.value = unreadable
            let result = await harness.runtime.refresh()
            let message = try XCTUnwrap(result.failure?.message)
            XCTAssertFalse(message.contains("SYNTHETIC-inference-key"), "the logged failure for HTTP \(unreadable.statusCode)")
        }
    }
}
