import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class DisplayCurrencyTests: XCTestCase {
    /// Frankfurter's `/v1/latest`, with round rates so the conversions read plainly.
    private nonisolated static let latest = #"{"amount":1.0,"base":"EUR","date":"2026-11-18","rates":{"CNY":8,"INR":180,"USD":2}}"#
    private static let now = Date(timeIntervalSince1970: 1_794_900_000)

    private static var rates: ExchangeRates {
        ExchangeRates(day: "2026-11-18", perEuroRates: ["CNY": 8, "INR": 180, "USD": 2], fetchedAt: now)
    }

    func testTheRatesAreWhatOneEuroBuys() throws {
        let rates = try ExchangeRateClient.parse(Data(Self.latest.utf8), fetchedAt: Self.now)

        XCTAssertEqual(rates, Self.rates)
        XCTAssertEqual(rates.perEuro("EUR"), 1)
        XCTAssertNil(rates.perEuro("XYZ"))
    }

    func testRatesOnAnotherBaseOrWithABadRateAreRefused() {
        for body in [
            #"{"base":"USD","date":"2026-11-18","rates":{"INR":90}}"#,
            #"{"base":"EUR","date":"2026-11-18","rates":{"INR":0}}"#,
            #"{"base":"EUR","date":"2026-11-18","rates":{"INR":"lots"}}"#,
            #"{"base":"EUR","date":"2026-11-18","rates":{}}"#,
            #"{"base":"EUR","rates":{"INR":180}}"#
        ] {
            XCTAssertThrowsError(try ExchangeRateClient.parse(Data(body.utf8), fetchedAt: Self.now), body)
        }
    }

    func testAmountsConvertThroughTheEuro() {
        let rupees = DisplayCurrency(code: "INR", rates: Self.rates)

        XCTAssertEqual(rupees.convert(10, from: "USD"), 900)
        XCTAssertEqual(rupees.convert(8, from: "CNY"), 180)
        XCTAssertEqual(rupees.convert(1, from: "EUR"), 180)
        XCTAssertEqual(rupees.convert(5, from: "INR"), 5)
        XCTAssertNil(rupees.convert(5, from: "XYZ"), "a currency the rates don't cover keeps its own amount")
        XCTAssertEqual(DisplayCurrency(code: "INR", fixedRates: ["USD": 80]).convert(10, from: "USD"), 800, "a fixed rate needs no ECB rates")
        XCTAssertEqual(DisplayCurrency.fixedRates(for: .plivo, in: "INR"), ["USD": 80])
        XCTAssertEqual(DisplayCurrency.fixedRates(for: .plivo, in: "EUR"), [:])
        XCTAssertEqual(DisplayCurrency.fixedRates(for: .deepseek, in: "INR"), [:])
    }

    func testMoneyFormatsInTheChosenCurrencyAndEverythingElseIsUntouched() {
        let rupees = DisplayCurrency(code: "INR", rates: Self.rates)

        XCTAssertEqual(MetricFormatter.number(10, kind: .dollars, style: .row, in: rupees), "₹900")
        XCTAssertEqual(MetricFormatter.number(0.5, kind: .dollars, style: .row, currencyCode: "CNY", in: rupees), "₹11.25")
        XCTAssertEqual(MetricFormatter.number(5, kind: .dollars, style: .row, currencyCode: "XYZ", in: rupees),
                       MetricFormatter.number(5, kind: .dollars, style: .row, currencyCode: "XYZ"))
        XCTAssertEqual(MetricFormatter.number(42, kind: .percent, style: .row, in: rupees), "42%")
        XCTAssertEqual(MetricFormatter.number(12, kind: .count, style: .row, in: rupees), "12")
    }

    func testTheDashboardShowsTheBalanceInRupeesWhileTheSnapshotKeepsDollars() async throws {
        let (store, runtime, rateRequests) = try makeStore(rates: { _ in .json(Self.latest) })
        store.displayCurrencyCode = "INR"

        await store.refreshExchangeRates()
        await store.refreshAll()

        let balance = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "balance" })
        XCTAssertEqual(store.data(for: balance).unboundedDetail, "₹382.50 left")
        XCTAssertEqual(store.snapshots[runtime.provider.id]?.lines, [
            .values(label: "Balance", values: [MetricValue(number: 4.25, kind: .dollars, currencyCode: "USD")])
        ])
        XCTAssertEqual(rateRequests.requests.count, 1, "rates under six hours old aren't read again")
        XCTAssertEqual(rateRequests.requests.first?.url, ExchangeRateClient.latestURL)
    }

    func testAsReportedShowsEachProvidersOwnCurrency() async throws {
        let (store, runtime, rateRequests) = try makeStore(rates: { _ in .json(Self.latest) })

        await store.refreshAll()

        let balance = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "balance" })
        XCTAssertEqual(store.data(for: balance).unboundedDetail, "$4.25 left")
        XCTAssertTrue(rateRequests.requests.isEmpty, "no rates are read until a currency is chosen")
    }

    func testRatesThatCantBeReadLeaveAmountsAsReported() async throws {
        let (store, runtime, _) = try makeStore(rates: { _ in .json("", status: 503) })
        store.displayCurrencyCode = "INR"

        await store.refreshExchangeRates()
        await store.refreshAll()

        let balance = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "balance" })
        XCTAssertTrue(store.exchangeRatesFailed)
        XCTAssertNil(store.displayCurrency(for: balance))
        XCTAssertEqual(store.data(for: balance).unboundedDetail, "$4.25 left")
    }

    func testTheChosenCurrenciesAndTheirRatesSurviveARelaunch() async throws {
        let defaults = isolatedDefaults()
        let (store, _, _) = try makeStore(defaults: defaults, rates: { _ in .json(Self.latest) })
        store.displayCurrencyCode = "INR"
        store.accountCurrencyCodes = ["deepseek@1": "CNY", "plivo@1": ""]
        await store.refreshExchangeRates()

        let (relaunched, _, rateRequests) = try makeStore(defaults: defaults, rates: { _ in .json(Self.latest) })
        await relaunched.refreshExchangeRates()

        XCTAssertEqual(relaunched.displayCurrencyCode, "INR")
        XCTAssertEqual(relaunched.accountCurrencyCodes, ["deepseek@1": "CNY", "plivo@1": ""])
        XCTAssertEqual(relaunched.exchangeRates, Self.rates)
        XCTAssertTrue(rateRequests.requests.isEmpty)
    }

    func testAnAccountsOwnCurrencyTakesThePlaceOfSettings() async throws {
        let (store, plivo, deepseek) = try plivoAndDeepSeekStore(rates: .json(Self.latest))
        let credits = try XCTUnwrap(plivo.widgetDescriptors.first { $0.key == "credits" })
        let balance = try XCTUnwrap(deepseek.widgetDescriptors.first { $0.key == "balance" })
        store.accountCurrencyCodes[plivo.provider.id] = "INR"

        await store.refreshExchangeRates()
        await store.refreshAll()

        XCTAssertEqual(store.data(for: credits).unboundedDetail, "₹200 left", "an account's own pick reads rates with nothing set in Settings")
        XCTAssertEqual(store.data(for: balance).unboundedDetail, "$4.25 left")

        store.displayCurrencyCode = "INR"
        store.accountCurrencyCodes[plivo.provider.id] = ""

        XCTAssertEqual(store.data(for: credits).unboundedDetail, "$2.50 left", "As Reported on the account wins over Settings")
        XCTAssertEqual(store.data(for: balance).unboundedDetail, "₹382.50 left")
    }

    func testRowsShowTheExactAmountAndRupeesGroupInLakhs() {
        let rupees = DisplayCurrency(code: "INR", rates: Self.rates)

        XCTAssertEqual(MetricFormatter.number(1250.5, kind: .dollars, style: .row, in: rupees), "₹1,12,545")
        XCTAssertEqual(MetricFormatter.number(21.4, kind: .dollars, style: .row, in: rupees), "₹1,926")
        XCTAssertEqual(MetricFormatter.number(21.41, kind: .dollars, style: .row, in: rupees), "₹1,926.90")
        XCTAssertEqual(MetricFormatter.number(1250.5, kind: .dollars, style: .tray, in: rupees), "₹112.5K", "the menu bar keeps the short form")
    }

    func testPlivoShowsDollarsAtEightyRupeesEvenWithoutTheDaysRates() async throws {
        for rates in [HTTPResponse.json(Self.latest), .json("", status: 503)] {
            let (store, plivo, deepseek) = try plivoAndDeepSeekStore(rates: rates)
            store.displayCurrencyCode = "INR"

            await store.refreshExchangeRates()
            await store.refreshAll()

            let credits = try XCTUnwrap(plivo.widgetDescriptors.first { $0.key == "credits" })
            let balance = try XCTUnwrap(deepseek.widgetDescriptors.first { $0.key == "balance" })
            XCTAssertEqual(store.data(for: credits).unboundedDetail, "₹200 left")
            XCTAssertEqual(store.data(for: balance).unboundedDetail, rates.statusCode == 200 ? "₹382.50 left" : "$4.25 left",
                           "other providers keep the ECB's rate")
        }
    }

    func testPlivoUsesTheDaysRateInAnyOtherCurrency() async throws {
        let (store, plivo, _) = try plivoAndDeepSeekStore(rates: .json(Self.latest))
        store.displayCurrencyCode = "CNY"

        await store.refreshExchangeRates()
        await store.refreshAll()

        let credits = try XCTUnwrap(plivo.widgetDescriptors.first { $0.key == "credits" })
        XCTAssertEqual(store.data(for: credits).unboundedDetail, "CN¥10 left")
    }

    private func plivoAndDeepSeekStore(rates: HTTPResponse) throws -> (WidgetDataStore, AccountProviderRuntime, AccountProviderRuntime) {
        let vault = InMemoryCredentialVault()
        let plivo = Account(kind: .plivo, label: "Plivo")
        let deepseek = Account(kind: .deepseek, label: "DeepSeek")
        try vault.save(.apiKey("MA123:token"), for: plivo.id)
        try vault.save(.apiKey("sk-deepseek"), for: deepseek.id)
        let http = RoutingHTTPClient { request in
            request.url.host() == "api.plivo.com"
                ? .json(#"{"billing_mode":"prepaid","cash_credits":"2.50000"}"#)
                : .json(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"4.25"}]}"#)
        }
        let runtimes = [AccountProviderRuntime(account: plivo, vault: vault, http: http),
                        AccountProviderRuntime(account: deepseek, vault: vault, http: http)]
        let store = WidgetDataStore.forTesting(
            runtimes, defaults: isolatedDefaults(), now: { Self.now },
            exchangeRateClient: ExchangeRateClient(http: RoutingHTTPClient { _ in rates })
        )
        return (store, runtimes[0], runtimes[1])
    }

    private func makeStore(
        defaults: UserDefaults? = nil,
        rates: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) throws -> (WidgetDataStore, AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .deepseek, label: "DeepSeek")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("sk-deepseek"), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: RoutingHTTPClient { _ in
            .json(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"4.25","granted_balance":"0.00","topped_up_balance":"4.25"}]}"#)
        })
        let rateHTTP = RoutingHTTPClient { rates($0) }
        let store = WidgetDataStore.forTesting(
            [runtime], defaults: defaults ?? isolatedDefaults(), now: { Self.now }, exchangeRateClient: ExchangeRateClient(http: rateHTTP)
        )
        return (store, runtime, rateHTTP)
    }
}
