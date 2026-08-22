import XCTest
@testable import OpenUsage

/// Crash reporting remains mandatory even when optional provider analytics are disabled.
final class TelemetrySinkTests: XCTestCase {
    func testErrorAutocaptureStaysEnabledRegardlessOfOptionalAnalytics() {
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: true),
            "crash autocapture must stay on when optional analytics are enabled"
        )
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: false),
            "crash autocapture must stay on when optional analytics are disabled"
        )
    }
}
