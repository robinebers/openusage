import XCTest
@testable import OpenUsage

@MainActor
final class SideNotchContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    func testRecapUsesUsageRegardlessOfGlobalRemainingModeAndIncludesReset() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let weekly = descriptor("codex.weekly", provider: provider, label: "Weekly")
        let session = descriptor("codex.session", provider: provider, label: "Session")

        var weeklyData = percentData(title: "Weekly", used: 54, displayMode: .remaining)
        weeklyData.resetsAt = now.addingTimeInterval(week / 2)
        weeklyData.periodDurationMs = Int(week * 1000)
        let sessionData = percentData(title: "Session", used: 20, displayMode: .remaining)
        let values = [weekly.id: weeklyData, session.id: sessionData]

        let content = SideNotchContentBuilder.build(
            groups: [ProviderMetrics(provider: provider, metrics: [weekly])],
            supportedMetrics: { _ in [weekly, session] },
            data: { values[$0.id]! },
            now: now
        )

        XCTAssertEqual(content.groups.count, 1)
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Session Limit", "Weekly Limit"])
        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["20%", "54%"])
        XCTAssertEqual(content.groups[0].metrics.map(\.usedHeadline), ["20% Used", "54% Used"])
        XCTAssertEqual(content.groups[0].primaryMetric.id, session.id)
        XCTAssertNil(content.groups[0].metrics[0].resetText)
        XCTAssertNotNil(content.groups[0].metrics[1].resetText)
    }

    func testWeeklyWindowWinsOverMonthlyWhenBothAreAvailable() {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let weekly = descriptor("opencode.weekly", provider: provider, label: "Weekly")
        let monthly = descriptor("opencode.monthly", provider: provider, label: "Monthly")
        let session = descriptor("opencode.session", provider: provider, label: "Session")
        let values = [
            weekly.id: percentData(title: "Weekly", used: 30),
            monthly.id: percentData(title: "Monthly", used: 40),
            session.id: percentData(title: "Session", used: 10),
        ]

        let content = SideNotchContentBuilder.build(
            groups: [ProviderMetrics(provider: provider, metrics: [weekly])],
            supportedMetrics: { _ in [weekly, monthly, session] },
            data: { values[$0.id]! },
            now: now
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Session Limit", "Weekly Limit"])
    }

    func testMonthlyWindowIsUsedWhenWeeklyIsUnavailable() {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let monthly = descriptor("opencode.monthly", provider: provider, label: "Monthly")
        let session = descriptor("opencode.session", provider: provider, label: "Session")
        let values = [
            monthly.id: percentData(title: "Monthly", used: 40),
            session.id: percentData(title: "Session", used: 10),
        ]

        let content = SideNotchContentBuilder.build(
            groups: [ProviderMetrics(provider: provider, metrics: [monthly])],
            supportedMetrics: { _ in [monthly, session] },
            data: { values[$0.id]! },
            now: now
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Session Limit", "Monthly Limit"])
    }

    func testRecapIncludesAvailableResetWithSoonestExpiration() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let weekly = descriptor("codex.weekly", provider: provider, label: "Weekly")
        let resets = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets",
            showsResetExpiries: true
        )
        let soonest = now.addingTimeInterval(8 * 24 * 60 * 60)
        var resetData = WidgetData(
            title: "Rate Limit Resets",
            icon: provider.icon,
            kind: .count,
            used: 0,
            limit: nil
        )
        resetData.values = [MetricValue(number: 2, kind: .count, label: "available")]
        resetData.showsResetExpiries = true
        resetData.expiriesAt = [now.addingTimeInterval(20 * 24 * 60 * 60), soonest]
        let values = [
            weekly.id: percentData(title: "Weekly", used: 30),
            resets.id: resetData,
        ]

        let content = SideNotchContentBuilder.build(
            groups: [ProviderMetrics(provider: provider, metrics: [weekly])],
            supportedMetrics: { _ in [weekly, resets] },
            data: { values[$0.id]! },
            now: now
        )

        let availableReset = try XCTUnwrap(content.groups[0].availableReset)
        XCTAssertEqual(availableReset.count, 2)
        XCTAssertEqual(availableReset.expiresAt, soonest)
        XCTAssertEqual(availableReset.severity, .normal)
    }

    func testRecapOmitsAvailableResetWhenExpiryIsUnknown() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let weekly = descriptor("codex.weekly", provider: provider, label: "Weekly")
        let resets = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets",
            showsResetExpiries: true
        )
        var resetData = WidgetData(
            title: "Rate Limit Resets",
            icon: provider.icon,
            kind: .count,
            used: 0,
            limit: nil
        )
        resetData.values = [MetricValue(number: 1, kind: .count, label: "available")]
        resetData.showsResetExpiries = true
        let values = [
            weekly.id: percentData(title: "Weekly", used: 30),
            resets.id: resetData,
        ]

        let content = SideNotchContentBuilder.build(
            groups: [ProviderMetrics(provider: provider, metrics: [weekly])],
            supportedMetrics: { _ in [weekly, resets] },
            data: { values[$0.id]! },
            now: now
        )

        XCTAssertNil(content.groups[0].availableReset)
    }

    func testTrafficLightsReserveRedForNinetyPercentAndUseYellowForProjectedOverage() {
        var normal = percentData(title: "Weekly", used: 14)
        normal.resetsAt = now.addingTimeInterval(week / 2)
        normal.periodDurationMs = Int(week * 1000)

        var projectedOver = percentData(title: "Weekly", used: 54)
        projectedOver.resetsAt = now.addingTimeInterval(week / 2)
        projectedOver.periodDurationMs = Int(week * 1000)

        var aboveNinety = percentData(title: "Weekly", used: 91)
        aboveNinety.resetsAt = now.addingTimeInterval(week * 0.95)
        aboveNinety.periodDurationMs = Int(week * 1000)

        XCTAssertEqual(SideNotchMeter.severity(for: normal, now: now), .normal)
        XCTAssertEqual(SideNotchMeter.severity(for: projectedOver, now: now), .warning)
        XCTAssertEqual(SideNotchMeter.severity(for: aboveNinety, now: now), .critical)
    }

    private func percentData(
        title: String,
        used: Double,
        displayMode: WidgetDisplayMode = .used
    ) -> WidgetData {
        WidgetData(
            title: title,
            icon: .providerMark("codex"),
            kind: .percent,
            used: used,
            limit: 100,
            displayMode: displayMode
        )
    }

    private func descriptor(_ id: String, provider: Provider, label: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: label,
            sample: percentData(title: label, used: 0)
        )
    }
}
