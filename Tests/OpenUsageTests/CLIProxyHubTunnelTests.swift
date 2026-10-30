import Foundation
import XCTest
@testable import OpenUsage

/// A mirrored account's unchanged Claude or ChatGPT runtime reads usage through the hub's `api-call`, a
/// wrong management key reaches the hub once, and every hub answer reads as an account-specific message.
@MainActor
final class CLIProxyHubTunnelTests: XCTestCase {
    nonisolated private static let hubURL = URL(string: "http://mini.local:8317")!
    nonisolated private static let claudeUsage = #"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#
    nonisolated private static let antigravitySummary = #"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-weekly","remainingFraction":0.75,"resetTime":"2099-01-01T00:00:00Z","window":"weekly"}]}]}"#
    nonisolated private static let devinStatus = #"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max"},"weeklyQuotaRemainingPercent":40}}}"#
    nonisolated private static let grokCredits = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2099-01-01T00:00:00Z","end":"2099-01-08T00:00:00Z"},"creditUsagePercent":25}}"#

    func testClaudeAndChatGPTReadUsageThroughTheHubWithTheirClientsUnchanged() async throws {
        let http = Self.hub { url, _ in
            url == ClaudeUsageClient.usageURL.absoluteString ? (200, Self.claudeUsage, [:]) : (200, #"{"rate_limit":{}}"#, [:])
        }
        let (runtimes, _, _) = try makeRuntimes(http: http, logins: [Self.login("a", "claude"), Self.login("b", "codex")])

        for runtime in runtimes {
            let result = await runtime.refresh()
            XCTAssertNil(result.failure, "\(runtime.account.kind): \(result.failure?.message ?? "")")
        }
        let claudeResult = await runtimes[0].refresh()
        let claude = try XCTUnwrap(claudeResult.success)
        XCTAssertFalse(claude.lines.isEmpty, "the Claude mapper read the tunnelled answer")

        let calls = try http.requests.map(Self.apiCall)
        XCTAssertTrue(http.requests.allSatisfy { $0.url.absoluteString == "http://mini.local:8317/v0/management/api-call" })
        XCTAssertTrue(http.requests.allSatisfy { $0.method == "POST" && $0.headers["Authorization"] == "Bearer mgmt-key" })
        let claudeCall = try XCTUnwrap(calls.first { $0.url == ClaudeUsageClient.usageURL.absoluteString })
        XCTAssertEqual(claudeCall.authIndex, "index-a")
        XCTAssertEqual(claudeCall.method, "GET")
        XCTAssertEqual(claudeCall.header["Authorization"], "Bearer $TOKEN$", "the hub puts its own token in")
        let codexCall = try XCTUnwrap(calls.first { $0.url == CodexUsageClient.usageURL.absoluteString })
        XCTAssertEqual(codexCall.authIndex, "index-b")
        XCTAssertEqual(codexCall.header["Authorization"], "Bearer $TOKEN$")
        XCTAssertEqual(codexCall.header["ChatGPT-Account-Id"], "acct-b")
    }

    func testAntigravityDevinAndGrokReadUsageThroughTheHubWithTheirClientsUnchanged() async throws {
        let http = Self.hub { url, _ in
            if url.hasSuffix(AntigravityUsageClient.loadCodeAssistPath) { return (200, #"{"cloudaicompanionProject":"p-1","currentTier":{"id":"free-tier","name":"Free"}}"#, [:]) }
            if url.hasSuffix(AntigravityUsageClient.quotaSummaryPath) { return (200, Self.antigravitySummary, [:]) }
            if url.hasSuffix("GetUserStatus") { return (200, Self.devinStatus, [:]) }
            if url == GrokUsageClient.creditsConfigURL.absoluteString { return (200, Self.grokCredits, [:]) }
            return (200, "{}", [:])
        }
        let (runtimes, _, _) = try makeRuntimes(http: http, logins: [Self.login("g", "antigravity"), Self.login("d", "devin"), Self.login("x", "xai")])
        XCTAssertEqual(runtimes.map(\.account.kind), [.antigravity, .devin, .grok])

        for runtime in runtimes {
            let result = await runtime.refresh()
            let snapshot = try XCTUnwrap(result.success, "\(runtime.account.kind): \(result.failure?.message ?? "")")
            XCTAssertFalse(snapshot.lines.isEmpty, "\(runtime.account.kind) mapped the tunnelled answer")
        }
        let calls = try http.requests.map(Self.apiCall)
        let quota = try XCTUnwrap(calls.first { $0.url.hasSuffix(AntigravityUsageClient.quotaSummaryPath) })
        XCTAssertEqual(quota.authIndex, "index-g")
        XCTAssertEqual(quota.header["Authorization"], "Bearer $TOKEN$", "the hub puts its own, refreshed token in")
        XCTAssertTrue(quota.data.contains("p-1"), "the quota read names the project from the first call")
        let devin = try XCTUnwrap(calls.first { $0.url.hasSuffix("GetUserStatus") })
        XCTAssertEqual(devin.authIndex, "index-d")
        XCTAssertTrue(devin.data.contains(#""apiKey":"$TOKEN$""#), "Devin's key goes in the body, where the hub substitutes it too")
        let grok = try XCTUnwrap(calls.first { $0.url == GrokUsageClient.creditsConfigURL.absoluteString })
        XCTAssertEqual(grok.authIndex, "index-x")
        XCTAssertEqual(grok.header["Authorization"], "Bearer $TOKEN$")
    }

    func testAWrongManagementKeyReachesTheHubOnceUntilTheKeyIsReplaced() async throws {
        let logins = (1...6).map { Self.login("l\($0)", "claude") }
        let http = Self.hub(key: "right-key", listing: Self.listing(logins)) { _, _ in (200, Self.claudeUsage, [:]) }
        let (runtimes, store, hub) = try makeRuntimes(http: http, logins: logins, key: "wrong-key")

        let messages = await withTaskGroup(of: String?.self) { group in
            for runtime in runtimes + runtimes { group.addTask { await runtime.refresh().failure?.message } }
            var messages: [String?] = []
            for await message in group { messages.append(message) }
            return messages
        }

        XCTAssertEqual(http.requests.count, 1, "one strike toward the hub's five-strike IP ban, not one per account")
        XCTAssertEqual(Set(messages), ["The CLIProxyAPI hub at mini.local:8317 rejected the management key. Replace it in Accounts."])
        _ = await runtimes[0].refresh()
        XCTAssertEqual(http.requests.count, 1, "nothing more goes to the hub")

        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: gate))
        do {
            try await sync.replaceKey("still-wrong", for: hub.id)
            XCTFail("a refused key is not saved")
        } catch {
            XCTAssertEqual(try store.credential(for: hub.id), .apiKey("wrong-key"))
        }
        try await sync.replaceKey("right-key", for: hub.id)
        XCTAssertEqual(try store.credential(for: hub.id), .apiKey("right-key"))
        XCTAssertEqual(store.accounts(onHub: hub.id).count, 6, "the same logins, unchanged")
        let resumed = await runtimes[0].refresh()
        XCTAssertNil(resumed.failure, "calls resume once the key is replaced")
    }

    func testALateRejectionOfTheReplacedKeyLeavesTheNewKeyWorking() async throws {
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let logins = [Self.login("a", "claude")]
        let hub = Self.hub(key: "right-key", listing: Self.listing(logins)) { _, _ in (200, Self.claudeUsage, [:]) }
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer wrong-key" {
                didStart.yield()
                for await _ in released { break }
            }
            return try await hub.send(request)
        }
        let (runtimes, store, hubAccount) = try makeRuntimes(http: http, logins: logins, key: "wrong-key")
        let stale = Task { await runtimes[0].refresh() }
        for await _ in started { break }

        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: gate))
        try await sync.replaceKey("right-key", for: hubAccount.id)
        release.yield()
        let staleResult = await stale.value
        XCTAssertEqual(staleResult.failure?.message, "The CLIProxyAPI hub at mini.local:8317 rejected the management key. Replace it in Accounts.")

        let sent = http.requests.count
        let fresh = await runtimes[0].refresh()
        XCTAssertNil(fresh.failure, "the old key's late 401 doesn't stop the new key")
        XCTAssertGreaterThan(http.requests.count, sent, "the new key's request reached the hub")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer right-key")
    }

    func testAnIPBanStopsCallsToo() async throws {
        let http = RoutingHTTPClient { _ in Self.json(403, #"{"error":"IP banned due to too many failed attempts. Try again in 29m12s"}"#) }
        let (runtimes, _, _) = try makeRuntimes(http: http, logins: [Self.login("a", "claude"), Self.login("b", "codex")])

        let first = await runtimes[0].refresh().failure
        let second = await runtimes[1].refresh().failure

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(first?.message, "The CLIProxyAPI hub at mini.local:8317 blocked this Mac after too many wrong keys. Wait 30 minutes, then replace the management key in Accounts.")
        XCTAssertEqual(second?.message, first?.message)
    }

    func testEveryHubAnswerReadsAsAnAccountSpecificMessage() async throws {
        let cases: [(name: String, answer: @Sendable () throws -> HTTPResponse, message: String, kind: RefreshFailure.Kind?)] = [
            ("remote management off", { Self.json(403, #"{"error":"remote management disabled"}"#) },
             "The CLIProxyAPI hub at mini.local:8317 only allows management from its own machine. Turn on allow-remote in its config.", .refused),
            ("management API off", { Self.json(404, "") },
             "The CLIProxyAPI hub at mini.local:8317 has its management API turned off. Set a management key in its config.", .refused),
            ("login gone", { Self.json(400, #"{"error":"auth credential not found for auth_index"}"#) },
             "This login is no longer on the CLIProxyAPI hub at mini.local:8317.", .refused),
            ("no token on the hub", { Self.json(400, #"{"error":"auth token not found"}"#) },
             "The CLIProxyAPI hub at mini.local:8317 has no working sign-in for this login. Sign it in again on the hub.", .refused),
            ("upstream unreachable", { Self.json(502, #"{"error":"request failed"}"#) },
             "The CLIProxyAPI hub at mini.local:8317 couldn’t reach Claude.", .unreachable),
            ("hub unreachable", { throw URLError(.cannotConnectToHost) },
             "Can’t reach the CLIProxyAPI hub at mini.local:8317.", .unreachable),
            ("upstream refused the hub's token", { Self.envelope(401, #"{"error":"unauthorized"}"#) },
             "The CLIProxyAPI hub at mini.local:8317 has no working sign-in for this login. Sign it in again on the hub.", .refused),
            ("an answer that isn't an envelope", { Self.json(200, "<html></html>") },
             ProviderError.invalidResponse.localizedDescription, .refused)
        ]
        for testCase in cases {
            let http = RoutingHTTPClient { _ in try testCase.answer() }
            let (runtimes, _, _) = try makeRuntimes(http: http, logins: [Self.login("a", "claude")])
            let failure = await runtimes[0].refresh().failure
            XCTAssertEqual(failure?.message, testCase.message, testCase.name)
            XCTAssertEqual(failure?.kind, testCase.kind, testCase.name)
        }
    }

    func testAnUpstreamRateLimitKeepsItsRetryAfter() async throws {
        let http = Self.hub { _, _ in (429, "{}", ["Retry-After": ["120"]]) }
        let (runtimes, _, _) = try makeRuntimes(http: http, logins: [Self.login("b", "codex")])
        let failure = await runtimes[0].refresh().failure
        XCTAssertEqual(failure?.kind, .rateLimited(retryAfter: 120))
    }

    func testAHubClaudeAccountShowsItsPlanOnItsFirstRefresh() async throws {
        let profile = #"{"account":{"uuid":"acc-1"},"organization":{"uuid":"6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#
        let http = Self.hub { url, _ in (200, url == ClaudeUsageClient.profileURL.absoluteString ? profile : Self.claudeUsage, [:]) }
        let (runtimes, _, _) = try makeRuntimes(http: http, logins: [Self.login("a", "claude")])

        let first = await runtimes[0].refresh()
        let snapshot = try XCTUnwrap(first.success)
        XCTAssertEqual(snapshot.plan, "Max 20x")
        let profileCalls = try http.requests.map(Self.apiCall).filter { $0.url == ClaudeUsageClient.profileURL.absoluteString }
        XCTAssertEqual(profileCalls.map(\.authIndex), ["index-a"])
        XCTAssertEqual(profileCalls.first?.header["Authorization"], "Bearer $TOKEN$")

        _ = await runtimes[0].refreshHourlyReads(of: snapshot)
        let again = try http.requests.map(Self.apiCall).filter { $0.url == ClaudeUsageClient.profileURL.absoluteString }
        XCTAssertEqual(again.count, 1, "the slot doesn't read the profile again within the hour")
        let next = await runtimes[0].refresh()
        XCTAssertEqual(next.success?.plan, "Max 20x")
    }

    func testARelinkedLoginGetsAFreshRuntimeAndARenameKeepsIt() throws {
        let http = Self.hub { _, _ in (200, Self.claudeUsage, [:]) }
        let (runtimes, store, hub) = try makeRuntimes(http: http, logins: [Self.login("a", "claude")])
        let account = store.accounts[0]

        store.rename(account.id, to: "Team")
        let renamed = ProviderCatalog.make(accounts: store.accounts, vault: store.credentialVault, http: http, hubGate: gate, reusing: runtimes)
        XCTAssertTrue(renamed[0] === runtimes[0])
        XCTAssertNotNil(renamed[0].provider.hubHost)

        store.mirror([Self.login("a", "claude", index: "moved")], from: hub.id)
        let relinked = ProviderCatalog.make(accounts: store.accounts, vault: store.credentialVault, http: http, hubGate: gate, reusing: renamed)
        XCTAssertFalse(relinked[0] === renamed[0], "the tunnel carries the login's auth index")
    }

    func testConnectingSavesNothingUntilTheHubAcceptsTheKey() async throws {
        let http = Self.hub(key: "right-key") { _, _ in (200, "{}", [:]) }
        let store = AccountStore(defaults: isolatedDefaults(), vault: RecordingVault())
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: gate))

        do {
            try await sync.connect(url: "mini.local:8317", key: "wrong-key")
            XCTFail("a wrong key connects nothing")
        } catch {}
        XCTAssertTrue(store.hubs.isEmpty)

        try await sync.connect(url: "http://mini.local:8317/management.html", key: " right-key ")
        let hub = try XCTUnwrap(store.hubs.first)
        XCTAssertEqual(hub.url, Self.hubURL)
        XCTAssertEqual(store.accounts(onHub: hub.id).count, 4, "the disabled login gets no account")
        XCTAssertEqual(sync.status(of: hub.id), .synced(unsupported: 1), "the Kimi login is counted, not shown")
        XCTAssertEqual(try store.credential(for: hub.id), .apiKey("right-key"))

        let listings = http.requests.count
        await sync.syncDue()
        XCTAssertEqual(http.requests.count, listings, "a hub read moments ago isn't read again")
        await sync.syncDue(maxAge: 0)
        XCTAssertEqual(http.requests.count, listings + 1)
    }

    // MARK: - Fake hub

    private let gate = CLIProxyHubGate()

    private func makeRuntimes(
        http: any HTTPClient, logins: [HubLogin], key: String = "mgmt-key"
    ) throws -> ([AccountProviderRuntime], AccountStore, CLIProxyHub) {
        let vault = RecordingVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        let hub = CLIProxyHub(url: Self.hubURL)
        try store.addHub(hub, key: key)
        store.mirror(logins, from: hub.id)
        let runtimes = ProviderCatalog.make(accounts: store.accounts, vault: vault, http: http, hubGate: gate)
        return (runtimes, store, hub)
    }

    private static func login(_ id: String, _ provider: String, index: String? = nil, disabled: Bool = false) -> HubLogin {
        HubLogin(
            id: id, authIndex: index ?? "index-\(id)", provider: provider, label: "\(id)@example.com", isOAuth: true,
            isDisabled: disabled, chatGPTAccountID: provider == "codex" ? "acct-\(id)" : nil
        )
    }

    /// A hub that checks the management key, lists the recorded logins, and answers each `api-call`
    /// with what `upstream` returns for its URL and headers.
    nonisolated private static func hub(
        key: String = "mgmt-key",
        listing: String = CLIProxyHubTests.recordedListing,
        upstream: @escaping @Sendable (String, [String: String]) -> (Int, String, [String: [String]])
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer \(key)" else { return json(401, #"{"error":"invalid management key"}"#) }
            switch request.url.path() {
            case "/v0/management/auth-files": return json(200, listing)
            case "/v0/management/api-call":
                let call = try apiCall(request)
                let (status, body, headers) = upstream(call.url, call.header)
                return envelope(status, body, headers: headers)
            default: return json(404, "")
            }
        }
    }

    nonisolated private static func listing(_ logins: [HubLogin]) -> String {
        let files = logins.map { login in
            ["id": login.id, "auth_index": login.authIndex, "provider": login.provider, "email": login.label, "account_type": "oauth", "disabled": login.isDisabled] as [String: Any]
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["files": files]), as: UTF8.self)
    }

    nonisolated private static func apiCall(_ request: HTTPRequest) throws -> (authIndex: String, method: String, url: String, header: [String: String], data: String) {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        return (
            payload["auth_index"] as? String ?? "", payload["method"] as? String ?? "", payload["url"] as? String ?? "",
            payload["header"] as? [String: String] ?? [:], payload["data"] as? String ?? ""
        )
    }

    nonisolated private static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["x-cpa-version": "v8.0.47"], body: Data(body.utf8))
    }

    /// An `api-call` answer in the shape CLIProxyAPI v8.0.47 sends: Go-cased header names with value lists.
    nonisolated private static func envelope(_ status: Int, _ body: String, headers: [String: [String]] = [:]) -> HTTPResponse {
        let envelope: [String: Any] = ["status_code": status, "header": headers.merging(["Content-Type": ["application/json"]]) { a, _ in a }, "body": body]
        return HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: envelope))
    }
}

private extension Result where Success == ProviderSnapshot, Failure == RefreshFailure {
    var success: ProviderSnapshot? {
        if case .success(let snapshot) = self { snapshot } else { nil }
    }
}
