import XCTest
@testable import OpenUsage

/// Anthropic budgets its usage endpoint per account and answers a reset-grants read sent right after a
/// usage read with a 429, so a pass reads plain usage only, the profile and the grants come in the
/// secondary-reads slot, a 429 holds every request to the login until its window ends (across a relaunch
/// too), and two cards for one login share one usage read.
@MainActor
final class ClaudeRequestCadenceTests: XCTestCase {
    private nonisolated static let start = OpenUsageISO8601.date(from: "2026-10-09T12:00:00.000Z")!
    private nonisolated static let orgUUID = "6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab"

    func testTheLaunchPassSendsOneRequestAndTheSlotReadsTheProfileAndGrants() async throws {
        let clock = TestClock(Self.start)
        let http = Self.anthropic()
        let runtime = try makeRuntime(http: http, clock: clock)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })

        await store.refreshAll()
        XCTAssertEqual(kinds(http), ["usage"])

        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval / 2))
        await store.refreshHourlyReads()
        XCTAssertEqual(kinds(http), ["usage", "profile", "grants"])
        let snapshot = try XCTUnwrap(store.snapshots[runtime.provider.id])
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(resetsAvailable(snapshot.lines), 1, "the row updates in the slot, not a pass later")
    }

    func testTheSlotReadsTheProfileAndGrantsHourly() async throws {
        let clock = TestClock(Self.start)
        let http = Self.anthropic()
        let runtime = try makeRuntime(http: http, clock: clock)

        for minutes in stride(from: 0, to: 60, by: 5) {
            clock.set(Self.start.addingTimeInterval(TimeInterval(minutes) * 60))
            let snapshot = try await runtime.refresh().get()
            clock.set(clock.now.addingTimeInterval(RefreshSetting.interval / 2))
            _ = await runtime.refreshHourlyReads(of: snapshot)
        }
        XCTAssertEqual(kinds(http).filter { $0 != "usage" }, ["profile", "grants"])

        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval / 2 + RefreshSetting.secondaryReadInterval))
        _ = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())
        XCTAssertEqual(kinds(http).filter { $0 != "usage" }, ["profile", "grants", "profile", "grants"])
    }

    func testAProfileReadCutShortByTheDeadlineIsRetriedInTheNextSlot() async throws {
        let clock = TestClock(Self.start)
        let anthropic = Self.anthropic()
        let http = RoutingHTTPClient { request in
            if Task.isCancelled { throw CancellationError() }
            return try await anthropic.send(request)
        }
        let runtime = try makeRuntime(http: http, clock: clock)
        let snapshot = try await runtime.refresh().get()

        let cut = Task { await runtime.refreshHourlyReads(of: snapshot) }
        cut.cancel()
        _ = await cut.value
        _ = await runtime.refreshHourlyReads(of: snapshot)

        XCTAssertEqual(kinds(http).filter { $0 == "profile" }.count, 2, "a cancelled read must not hold the plan back for an hour")
    }

    func testARetryAfterOfZeroWaitsFiveMinutesThenTen() async throws {
        let clock = TestClock(Self.start)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "0"], body: Data()) }
        let runtime = try makeRuntime(http: http, clock: clock)

        _ = await runtime.refresh()
        for (offset, sent) in [(299.0, 1), (300, 2), (899, 2), (900, 3)] {
            clock.set(Self.start.addingTimeInterval(offset))
            let snapshot = await runtime.refresh()
            XCTAssertEqual(http.requests.count, sent, "at \(Int(offset))s")
            XCTAssertNotNil(snapshot.failure, "at \(Int(offset))s")
        }
        clock.set(Self.start.addingTimeInterval(1_000))
        let third = await runtime.refresh()
        XCTAssertEqual(third.failure?.kind, .rateLimited(retryAfter: 1_100), "the third 429 waits 20 minutes")
    }

    func testA429OnTheGrantsReadHoldsEveryRequestToTheLogin() async throws {
        let clock = TestClock(Self.start)
        let http = Self.anthropic(grants: { HTTPResponse(statusCode: 429, headers: ["retry-after": "3000"], body: Data()) })
        let runtime = try makeRuntime(http: http, clock: clock)

        _ = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        let gated = await runtime.refresh()

        XCTAssertEqual(kinds(http), ["usage", "profile", "grants"])
        XCTAssertEqual(gated.failure?.kind, .rateLimited(retryAfter: 3000 - RefreshSetting.interval))
    }

    func testTheWindowHoldsAcrossARelaunch() async throws {
        let clock = TestClock(Self.start)
        let defaults = isolatedDefaults()
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "1800"], body: Data()) }
        let account = Account(kind: .claude, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token-a")), for: account.id)
        func launch() -> WidgetDataStore {
            let runtime = AccountProviderRuntime(
                account: account, vault: vault, http: http, now: { clock.now }, claudeSessions: ClaudeSessions(defaults: defaults)
            )
            return WidgetDataStore.forTesting([runtime], defaults: defaults, now: { clock.now })
        }
        await launch().refreshAll()
        XCTAssertEqual(http.requests.count, 1)

        clock.set(Self.start.addingTimeInterval(600))
        let relaunched = launch()
        await relaunched.refreshAll()

        XCTAssertEqual(http.requests.count, 1, "nothing goes to the login inside its window")
        let retryAt = Self.start.addingTimeInterval(1800)
        XCTAssertEqual(
            relaunched.stalenessHint(for: account.cardID),
            "Claude asked OpenUsage to wait. Retrying at \(Formatters.compactClock(retryAt, now: clock.now))."
        )
    }

    func testTwoCardsForOneLoginSendOneUsageRequest() async throws {
        let clock = TestClock(Self.start)
        let http = RoutingHTTPClient { request in
            try await Task.sleep(for: .milliseconds(100))
            return Self.usage()
        }
        let sessions = ClaudeSessions()
        let runtimes = try ["Work", "Again"].map { label in
            let account = Account(kind: .claude, label: label)
            let vault = InMemoryCredentialVault()
            try vault.save(.oauth(OAuthTokens(accessToken: "token-\(label)", extras: [OAuthTokens.identityKey: "acct/org"])), for: account.id)
            return AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now }, claudeSessions: sessions)
        }
        let store = WidgetDataStore.forTesting(runtimes, defaults: isolatedDefaults(), now: { clock.now })

        await store.refreshAll()

        XCTAssertEqual(http.requests.count, 1)
        for runtime in runtimes {
            XCTAssertEqual(store.snapshots[runtime.provider.id]?.line(label: "Session"), .percent("Session", 42, resetsAt: Self.farFuture, periodMs: MetricPeriod.sessionMs))
        }
    }

    func testASuccessThatStartedBeforeA429KeepsThe429sWindow() async throws {
        let sessions = ClaudeSessions()
        let session = sessions.session(for: "acct/org")
        let slowRead = HeldResponse()
        let slow = Task {
            try await session.send(at: Self.start) {
                await slowRead.hold()
                return Self.usage()
            }
        }
        await slowRead.waitUntilHeld()
        do {
            _ = try await session.send(at: Self.start) { HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data()) }
            XCTFail("a 429 was accepted")
        } catch {}
        await slowRead.release()
        _ = try await slow.value

        XCTAssertEqual(session.wait(at: Self.start), 600, "a success sent before the 429 ended its window")
    }

    func testAForcedRefreshReadsTheGrantsOnlyOnceTheLastCheckIsFifteenMinutesOld() async throws {
        let clock = TestClock(Self.start)
        let http = Self.anthropic()
        let runtime = try makeRuntime(http: http, clock: clock)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        await store.refreshAll()
        await store.refreshHourlyReads()

        clock.set(Self.start.addingTimeInterval(5 * 60))
        await store.refreshAll(force: true)
        XCTAssertEqual(kinds(http), ["usage", "profile", "grants", "usage", "profile"])

        clock.set(Self.start.addingTimeInterval(RefreshSetting.forcedResetGrantsMinimumAge))
        await store.refreshAll(force: true)
        XCTAssertEqual(kinds(http).suffix(3), ["usage", "grants", "profile"])
    }

    func testAClaimRefreshesTheMetersAtOnceWithoutAGrantsRead() async throws {
        let clock = TestClock(Self.start)
        let http = Self.anthropic(claim: { Self.json(#"{"result":"reset","resets_left":0,"cleared":["five_hour"]}"#) })
        let runtime = try makeRuntime(http: http, clock: clock)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        await store.refreshAll()
        await store.refreshHourlyReads()
        let refreshed = expectation(description: "the post-claim refresh")
        let service = try XCTUnwrap(runtime.resetClaimService {
            defer { refreshed.fulfill() }
            return await store.refresh(providerID: runtime.provider.id, force: true)
        })
        let sentBefore = http.requests.count

        let outcome = await service.claim(creditExpiringAt: Self.start, redeemRequestID: "redeem-1")
        await fulfillment(of: [refreshed], timeout: 1)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(kinds(http).dropFirst(sentBefore), ["claim", "usage"])
        XCTAssertEqual(resetsAvailable(store.snapshots[runtime.provider.id]?.lines ?? []), 0)
    }

    func testSpendingAGrantsLastResetLetsTheNextGrantBeClaimedAfterTheNextGrantsRead() async throws {
        let clock = TestClock(Self.start)
        let claimed = TestSwitch(false)
        let http = Self.anthropic(
            grants: {
                let (left, next) = claimed.value ? (0, "b") : (1, "a")
                return Self.json(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_left":\#(left)},{"id":"b","resets_left":1}],"next_grant_id":"\#(next)"}}"#)
            },
            claim: {
                claimed.value = true
                return Self.json(#"{"result":"reset","resets_left":0,"cleared":["five_hour"]}"#)
            }
        )
        let runtime = try makeRuntime(http: http, clock: clock)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        await store.refreshAll()
        await store.refreshHourlyReads()
        let refreshed = expectation(description: "the post-claim refresh")
        let service = try XCTUnwrap(runtime.resetClaimService {
            defer { refreshed.fulfill() }
            return await store.refresh(providerID: runtime.provider.id, force: true)
        })
        let outcome = await service.claim(creditExpiringAt: Self.start, redeemRequestID: "redeem-1")
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(outcome, .success)

        await store.refreshHourlyReads()

        XCTAssertEqual(runtime.resetClaimService { .refreshed }?.isClaimable, true, "grant b's reset waits for the hourly grants read")
    }

    func testTheHeldResetsRowDropsAGrantOnceItsDeadlinePasses() async throws {
        let clock = TestClock(Self.start)
        let deadline = Self.start.addingTimeInterval(10 * 60)
        let http = Self.anthropic(grants: { Self.grants(resetsLeft: 1, endsAt: deadline) })
        let runtime = try makeRuntime(http: http, clock: clock)

        let first = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())
        clock.set(Self.start.addingTimeInterval(15 * 60))
        let later = try await runtime.refresh().get()

        XCTAssertEqual(resetsAvailable(first?.lines ?? []), 1)
        XCTAssertEqual(resetsAvailable(later.lines), 0)
    }

    func testAFailedGrantsReadKeepsTheLastRowForTheHour() async throws {
        let clock = TestClock(Self.start)
        let down = TestSwitch(false)
        let http = Self.anthropic(grants: {
            down.value ? HTTPResponse(statusCode: 500, headers: [:], body: Data()) : Self.grants(resetsLeft: 1)
        })
        let runtime = try makeRuntime(http: http, clock: clock)
        _ = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())

        down.value = true
        clock.set(Self.start.addingTimeInterval(RefreshSetting.secondaryReadInterval))
        let failed = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())
        clock.set(clock.now.addingTimeInterval(RefreshSetting.interval))
        let next = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())

        let shown = try await runtime.refresh().get()

        XCTAssertNil(failed, "the row the last good read showed stays")
        XCTAssertNil(next)
        XCTAssertEqual(resetsAvailable(shown.lines), 1)
        XCTAssertEqual(kinds(http).filter { $0 == "grants" }.count, 2, "a failed read waits for the next hour")
    }

    func testEachLoginReadsItsOwnGrants() async throws {
        let clock = TestClock(Self.start)
        let http = RoutingHTTPClient { request in
            guard request.url.path == "/api/oauth/usage" else { return HTTPResponse(statusCode: 404, headers: [:], body: Data()) }
            guard request.isClaudeResetGrantsCheck else { return Self.usage() }
            return Self.grants(resetsLeft: request.headers["Authorization"] == "Bearer token-a" ? 1 : 2)
        }
        let sessions = ClaudeSessions()
        let runtimes = try ["token-a", "token-p"].map { token in
            let account = Account(kind: .claude, label: token)
            let vault = InMemoryCredentialVault()
            try vault.save(.oauth(OAuthTokens(accessToken: token)), for: account.id)
            return AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now }, claudeSessions: sessions)
        }

        var rows: [Double?] = []
        for runtime in runtimes {
            rows.append(resetsAvailable(await runtime.refreshHourlyReads(of: try await runtime.refresh().get())?.lines ?? []))
        }

        XCTAssertEqual(rows, [1, 2])
        XCTAssertEqual(
            http.requests.filter(\.isClaudeResetGrantsCheck).map { $0.headers["Authorization"] },
            ["Bearer token-a", "Bearer token-p"]
        )
    }

    private nonisolated static let farFuture = OpenUsageISO8601.date(from: "2099-01-01T00:00:00.000Z")!

    private func makeRuntime(http: RoutingHTTPClient, clock: TestClock) throws -> AccountProviderRuntime {
        let account = Account(kind: .claude, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token-a", refreshToken: "refresh-a")), for: account.id)
        return AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
    }

    private func kinds(_ http: RoutingHTTPClient) -> [String] {
        http.requests.map { request in
            switch request.url.path {
            case "/api/oauth/usage": request.isClaudeResetGrantsCheck ? "grants" : "usage"
            case "/api/oauth/profile": "profile"
            default: request.url.path.hasSuffix("/reset_rate_limits") ? "claim" : request.url.path
            }
        }
    }

    private func resetsAvailable(_ lines: [MetricLine]) -> Double? {
        guard case .values(_, let values, _) = lines.first(where: { $0.label == ClaudeResetGrantStatus.lineLabel }) else {
            return nil
        }
        return values.first?.number
    }

    private nonisolated static func anthropic(
        grants: @escaping @Sendable () -> HTTPResponse = { grants(resetsLeft: 1) },
        claim: @escaping @Sendable () -> HTTPResponse = { HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage":
                return request.isClaudeResetGrantsCheck ? grants() : usage()
            case "/api/oauth/profile":
                return json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"\#(orgUUID)","organization_type":"claude_max"}}"#)
            case "/api/organizations/\(orgUUID)/reset_rate_limits":
                return claim()
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
    }

    private nonisolated static func usage() -> HTTPResponse {
        json(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#)
    }

    private nonisolated static func grants(resetsLeft: Int, endsAt: Date? = nil) -> HTTPResponse {
        let endsAtJSON = endsAt.map { "\"\(OpenUsageISO8601.string(from: $0))\"" } ?? "null"
        return json(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":\#(resetsLeft),"ends_at":\#(endsAtJSON)}],"next_grant_id":"g"}}"#)
    }

    private nonisolated static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(text.utf8))
    }
}
