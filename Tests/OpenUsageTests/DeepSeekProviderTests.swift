import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    /// `/user/balance` as DeepSeek's API reference documents it.
    private nonisolated static let documented = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#

    private func runtime(
        _ answer: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) throws -> (AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .deepseek, label: "DeepSeek")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("sk-deepseek"), for: account.id)
        let http = RoutingHTTPClient { answer($0) }
        return (AccountProviderRuntime(account: account, vault: vault, http: http), http)
    }

    func testBalanceIsTheTotalInTheAccountsCurrency() async throws {
        let (runtime, http) = try runtime { _ in .json(Self.documented) }

        let snapshot = try await runtime.refresh().get()

        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines, [.values(label: "Balance", values: [MetricValue(number: 110, kind: .dollars, currencyCode: "CNY")])])
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, DeepSeekUsageClient.balanceURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-deepseek")
        XCTAssertEqual(runtime.widgetDescriptors.map(\.key), ["balance"])
    }

    func testABalanceInEachCurrencyShowsBoth() async throws {
        let (runtime, _) = try runtime { _ in
            .json(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"4.25","granted_balance":"0.00","topped_up_balance":"4.25"},{"currency":"cny","total_balance":"0","granted_balance":"0","topped_up_balance":"0"}]}"#)
        }

        let lines = try await runtime.refresh().get().lines

        XCTAssertEqual(lines, [.values(label: "Balance", values: [
            MetricValue(number: 4.25, kind: .dollars, currencyCode: "USD"),
            MetricValue(number: 0, kind: .dollars, currencyCode: "CNY")
        ])])
    }

    func testAnEmptyBalanceStillShowsAtZero() async throws {
        let (runtime, _) = try runtime { _ in
            .json(#"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#)
        }
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())

        await store.refreshAll()

        let balance = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "balance" })
        XCTAssertEqual(store.data(for: balance).unboundedDetail, "$0 left")
    }

    func testNoBalanceListedSaysSo() async throws {
        let (runtime, _) = try runtime { _ in .json(#"{"is_available":false,"balance_infos":[]}"#) }

        let failure = await runtime.refresh()

        XCTAssertEqual(failure.failure?.message, "DeepSeek reports no balance for this account.")
    }

    func testAMalformedBalanceIsAnInvalidResponse() async throws {
        for body in [
            #"{"is_available":true}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY"}]}"#,
            #"{"is_available":true,"balance_infos":[{"total_balance":"1.00"}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"yuan","total_balance":"1.00"}]}"#
        ] {
            let (runtime, _) = try runtime { _ in .json(body) }

            let failure = await runtime.refresh()

            XCTAssertEqual(failure.failure?.message, ProviderError.invalidResponse.localizedDescription, body)
        }
    }
}
