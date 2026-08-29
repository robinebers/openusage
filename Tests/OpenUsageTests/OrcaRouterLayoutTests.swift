import XCTest
@testable import OpenUsage

/// Locks OrcaRouter's default metric placement (consistent with OpenRouter): Total Usage above the
/// fold and pinned, the wallet Balance and Free Credit rows below the caret.
final class OrcaRouterLayoutTests: XCTestCase {
    private let aboveFold = ["orcarouter.totalUsage"]
    private let belowCaret = ["orcarouter.balance", "orcarouter.freeCredit"]

    func testAllMetricsEnabledByDefault() {
        for id in aboveFold + belowCaret {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled by default")
        }
    }

    func testTotalUsageStaysAboveTheFold() {
        for id in aboveFold {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should stay above the fold")
        }
    }

    func testBalanceRowsSitBelowTheCaret() {
        for id in belowCaret {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should sit below the caret")
        }
    }

    func testTotalUsagePinnedByDefault() {
        XCTAssertTrue(
            DefaultLayout.pinnedMetricIDs.contains("orcarouter.totalUsage"),
            "Total Usage should be pinned to the menu bar"
        )
    }
}
