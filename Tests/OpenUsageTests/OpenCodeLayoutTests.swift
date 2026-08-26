import XCTest
@testable import OpenUsage

/// Locks OpenCode's default metric placement (owner-confirmed, consistent with every other provider):
/// the three Go caps and the Usage Trend above the fold, the spend tiles below the caret, nothing pinned.
final class OpenCodeLayoutTests: XCTestCase {
    private let aboveFold = ["opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend"]
    private let defaultBelowCaret = ["opencode.today", "opencode.yesterday", "opencode.last30"]
    private let optionalBelowCaret = ["opencode.monthToDate"]

    func testAllMetricsEnabledByDefault() {
        for id in aboveFold + defaultBelowCaret {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled by default")
        }
        for id in optionalBelowCaret {
            XCTAssertFalse(DefaultLayout.metricIDs.contains(id), "\(id) should be opt-in")
        }
    }

    func testCapsAndTrendStayAboveTheFold() {
        for id in aboveFold {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should stay above the fold")
        }
    }

    func testSpendTilesSitBelowTheCaret() {
        for id in defaultBelowCaret + optionalBelowCaret {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should sit below the caret")
        }
    }

    func testNothingPinnedByDefault() {
        XCTAssertFalse(
            DefaultLayout.pinnedMetricIDs.contains { $0.hasPrefix("opencode.") },
            "a freshly auto-enabled provider adds no menu-bar pins (matches Grok/Devin)"
        )
    }
}
