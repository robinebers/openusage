import XCTest
import OpenUsageWidgetSupport
@testable import OpenUsage

@MainActor
final class DesktopWidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBoundedMetricUsesTheSameDisplayModeAndSeverityAsTheApp() throws {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.percent(
            id: "claude.session",
            provider: provider,
            title: "Session"
        )
        var data = WidgetData(
            title: "Session",
            icon: provider.icon,
            kind: .percent,
            used: 85,
            limit: 100
        )
        data.displayMode = .remaining

        let metric = DesktopWidgetSnapshotBuilder.makeMetric(
            providerName: "Claude Team",
            descriptor: descriptor,
            data: data,
            now: now
        )

        XCTAssertEqual(metric.providerName, "Claude Team")
        XCTAssertEqual(metric.value, "15% left")
        XCTAssertEqual(try XCTUnwrap(metric.progress), 0.15, accuracy: 0.0001)
        XCTAssertEqual(metric.status, .warning)
    }

    func testUnboundedAndMissingMetricsDoNotInventProgress() {
        let provider = Provider(id: "openrouter", displayName: "OpenRouter", icon: .providerMark("openrouter"))
        let descriptor = WidgetDescriptor.dollarBalance(
            id: "openrouter.balance",
            provider: provider,
            title: "Balance",
            valueWord: "left"
        )
        var available = WidgetData(
            title: "Balance",
            icon: provider.icon,
            kind: .dollars,
            used: 18.42,
            limit: nil,
            valueTextOverride: "$18.42 left"
        )

        let metric = DesktopWidgetSnapshotBuilder.makeMetric(
            providerName: provider.displayName,
            descriptor: descriptor,
            data: available,
            now: now
        )
        XCTAssertEqual(metric.value, "$18.42 left")
        XCTAssertNil(metric.progress)
        XCTAssertEqual(metric.status, .neutral)

        available.hasData = false
        let missing = DesktopWidgetSnapshotBuilder.makeMetric(
            providerName: provider.displayName,
            descriptor: descriptor,
            data: available,
            now: now
        )
        XCTAssertEqual(missing.value, "—")
        XCTAssertEqual(missing.subtitle, "No data")
        XCTAssertNil(missing.progress)
        XCTAssertEqual(missing.status, .neutral)
    }

    func testDeepLinkSeparatesDevelopmentAndProductionBuilds() {
        XCTAssertEqual(
            DesktopWidgetDeepLink.dashboardURL(bundleIdentifier: "com.robinebers.openusage.dev.widget").absoluteString,
            "openusage-dev://dashboard"
        )
        XCTAssertEqual(
            DesktopWidgetDeepLink.dashboardURL(bundleIdentifier: "com.robinebers.openusage.widget").absoluteString,
            "openusage://dashboard"
        )
    }
}
