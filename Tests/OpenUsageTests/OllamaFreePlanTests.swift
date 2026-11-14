import XCTest
@testable import OpenUsage

/// A free ollama.com account: no allowance, no session or weekly limits, no purchased credits, no usage.
@MainActor
final class OllamaFreePlanTests: XCTestCase {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_793_392_200)
    nonisolated private static let utcToday = 1_793_318_400
    nonisolated static let account = #"{"ID":"u1","Email":"free@example.com","Name":"free","Plan":"free"}"#
    nonisolated static let balance = #"{"included":{"balance_usd":0,"allowance_usd":0,"period":{"from":"2026-10-14T00:00:00Z","until":"2026-11-14T00:00:00Z"}},"purchased":{"balance_usd":0}}"#

    /// Every day in the range answered with zeros and no model groups, as ollama.com does for an unused key.
    nonisolated static func usage(_ request: HTTPRequest) -> HTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let range = query.first { $0.name == "range" }?.value ?? "7d"
        let days = range == "30d" ? 30 : 7
        let iso = ISO8601DateFormatter()
        let zeros = #""request_count":0,"usage_usd":0,"input_tokens":0,"cached_input_tokens":0,"output_tokens":0"#
        let buckets = (0...days).reversed().map { daysAgo in
            let from = Date(timeIntervalSince1970: TimeInterval(utcToday - daysAgo * 86_400))
            let until = daysAgo == 0 ? now : from.addingTimeInterval(86_400)
            return #"{"from":"\#(iso.string(from: from))","until":"\#(iso.string(from: until))",\#(zeros),"groups":[]}"#
        }
        let start = iso.string(from: Date(timeIntervalSince1970: TimeInterval(utcToday - days * 86_400)))
        let body = #"{"range":"\#(range)","scope":"self","granularity":"day","group_by":"model","from":"\#(start)","#
            + #""until":"\#(iso.string(from: now))","totals":{\#(zeros)},"buckets":[\#(buckets.joined(separator: ","))]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    nonisolated static func route(balance: String) -> @Sendable (HTTPRequest) async throws -> HTTPResponse {
        { request in
            switch request.url.path {
            case OllamaUsageClient.balancePath: HTTPResponse(statusCode: 200, headers: [:], body: Data(balance.utf8))
            case OllamaUsageClient.usagePath: usage(request)
            default: HTTPResponse(statusCode: 200, headers: [:], body: Data(account.utf8))
            }
        }
    }

    private func refresh(balance: String) async throws -> (WidgetDataStore, AccountProviderRuntime) {
        let account = Account(kind: .ollama, label: "free@example.com")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("ollama-key"), for: account.id)
        let clock = TestClock(Self.now)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: RoutingHTTPClient(handler: Self.route(balance: balance)),
                                             now: { clock.now })
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
        return (store, runtime)
    }

    func testAFreeAccountRefreshesWithAZeroBalanceZeroUsageAndNoMonthlyRow() async throws {
        let (store, runtime) = try await refresh(balance: Self.balance)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(store.plan(for: runtime.provider.id), "Free")
        var shown: [String: String] = [:]
        for descriptor in runtime.widgetDescriptors {
            let data = store.data(for: descriptor)
            if data.hasData { shown[descriptor.key] = data.unboundedDetail }
        }
        XCTAssertEqual(shown, [
            "purchasedCredits": "$0 left",
            "today": "$0 · 0 tokens",
            "yesterday": "$0 · 0 tokens",
            "last30": "$0 · 0 tokens",
            "requests": "0 in 30 days"
        ], "a $0 allowance is no monthly allowance; the balance and the usage rows show at 0")
    }

    func testABalanceBodyWithoutAnIncludedObjectIsStillInvalid() async throws {
        for body in [#"{"purchased":{"balance_usd":0}}"#, #"{"ok":true}"#, "[]"] {
            let (store, runtime) = try await refresh(balance: body)
            XCTAssertEqual(store.errorMessage(for: runtime.provider.id), ProviderError.invalidResponse.localizedDescription, body)
        }
    }
}
