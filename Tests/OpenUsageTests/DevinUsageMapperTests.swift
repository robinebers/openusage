import Foundation
import XCTest
@testable import OpenUsage

final class DevinUsageMapperTests: XCTestCase {
    private let dailyReset = Date(timeIntervalSince1970: 1_774_080_000)
    private let weeklyReset = Date(timeIntervalSince1970: 1_774_166_400)

    func testMapsThePlanBothQuotasAsUsedAndTheBalanceInDollars() throws {
        let usage = try map(#"""
        {"planInfo":{"planName":" Max ","billingStrategy":"BILLING_STRATEGY_QUOTA"},
         "dailyQuotaRemainingPercent":100,"weeklyQuotaRemainingPercent":40,"overageBalanceMicros":"964220000",
         "dailyQuotaResetAtUnix":"1774080000","weeklyQuotaResetAtUnix":"1774166400"}
        """#)

        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(usage.lines, [
            .percent("Daily quota", 0, resetsAt: dailyReset, periodMs: MetricPeriod.dayMs),
            .percent("Weekly quota", 60, resetsAt: weeklyReset, periodMs: MetricPeriod.weekMs),
            .values(label: "Extra usage balance", values: [MetricValue(number: 964.22, kind: .dollars)])
        ])
    }

    func testAZeroOrNegativeBalanceReadsZeroDollars() throws {
        for micros in [#""0""#, #""-44347""#] {
            let usage = try map(#"{"weeklyQuotaRemainingPercent":40,"overageBalanceMicros":\#(micros)}"#)
            XCTAssertEqual(usage.lines.last, .values(label: "Extra usage balance", values: [MetricValue(number: 0, kind: .dollars)]), micros)
        }
    }

    func testAHiddenDailyQuotaFillsTheWeeklyRowWhenThereIsNoWeeklyQuota() throws {
        let usage = try map(#"""
        {"planInfo":{"planName":"Pro","hideDailyQuota":true},"dailyQuotaRemainingPercent":30,"dailyQuotaResetAtUnix":"1774080000"}
        """#)

        XCTAssertEqual(usage.lines, [.percent("Weekly quota", 70, periodMs: MetricPeriod.weekMs)])
    }

    func testAnOmittedWeeklyShareBesideAResetIsUsedUp() throws {
        for hideDailyQuota in [true, false] {
            let usage = try map(#"""
            {"planInfo":{"planName":"Max","hideDailyQuota":\#(hideDailyQuota)},
             "dailyQuotaRemainingPercent":100,"dailyQuotaResetAtUnix":"1774080000","weeklyQuotaResetAtUnix":"1774166400"}
            """#)

            XCTAssertEqual(
                usage.lines.first { $0.label == "Weekly quota" },
                .percent("Weekly quota", 100, resetsAt: weeklyReset, periodMs: MetricPeriod.weekMs),
                "hideDailyQuota \(hideDailyQuota)"
            )
        }
    }

    func testAnOmittedDailyShareBesideAResetIsUsedUp() throws {
        let usage = try map(#"{"weeklyQuotaRemainingPercent":40,"dailyQuotaResetAtUnix":"1774080000"}"#)

        XCTAssertEqual(usage.lines.first, .percent("Daily quota", 100, resetsAt: dailyReset, periodMs: MetricPeriod.dayMs))
    }

    func testAnUnreadableShareIsAnInvalidResponseNotAUsedUpQuota() {
        for key in ["dailyQuotaRemainingPercent", "weeklyQuotaRemainingPercent"] {
            for malformed in [#""abc""#, "true", "{}"] {
                XCTAssertThrowsError(try map(#"""
                {"\#(key)":\#(malformed),"dailyQuotaResetAtUnix":"1774080000","weeklyQuotaResetAtUnix":"1774166400"}
                """#), "\(key): \(malformed)") { error in
                    XCTAssertEqual(error as? ProviderError, .invalidResponse)
                }
            }
        }
    }

    func testAnAccountWithNoQuotaAndNoBalanceSaysSo() {
        XCTAssertThrowsError(try map(#"{"planInfo":{"planName":"Max"}}"#)) { error in
            XCTAssertEqual(error.localizedDescription, "Devin reports no quota for this account.")
        }
    }

    func testABodyWithoutAUserStatusIsAnInvalidResponse() {
        XCTAssertThrowsError(try DevinUsageMapper.map(Data(#"{"code":"internal"}"#.utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    private func map(_ planStatus: String) throws -> ProviderUsage {
        try DevinUsageMapper.map(Data(#"{"userStatus":{"planStatus":\#(planStatus)}}"#.utf8))
    }
}
