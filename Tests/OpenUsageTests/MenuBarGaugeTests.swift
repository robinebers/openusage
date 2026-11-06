import AppKit
import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarGaugeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claude = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let codex = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")

    private func limit(
        _ title: String,
        used: Double,
        limit: Double = 100,
        periodDurationMs: Int? = nil,
        resetsAt: Date? = nil
    ) -> WidgetData {
        var data = WidgetData(title: title, kind: .percent, used: used, limit: limit)
        data.periodDurationMs = periodDurationMs
        data.resetsAt = resetsAt
        return data
    }

    private func account(_ provider: Provider, _ lines: WidgetData...) -> DashboardAccount {
        DashboardAccount(provider: provider, lines: lines.map { data in
            DashboardLine(
                descriptor: WidgetDescriptor(provider: provider, key: data.title, metricLabel: data.title, sample: data),
                data: data
            )
        })
    }

    func testMenuBarStyleLabelsAndCases() {
        XCTAssertEqual(MenuBarStyle.allCases.map(\.label), ["Text", "Bars", "Gauge", "Color Gauge"])
    }

    func testGaugeExtracts5hForTopAnd7dForBottom() {
        let session = limit("Session", used: 33, limit: 100, periodDurationMs: 5 * 3600 * 1000, resetsAt: now.addingTimeInterval(3600))
        let weekly = limit("Weekly", used: 27, limit: 100, periodDurationMs: 7 * 24 * 3600 * 1000, resetsAt: now.addingTimeInterval(4 * 24 * 3600))
        let acc = account(claude, session, weekly)
        let board = PriorityBoard.make(accounts: [acc], now: now)

        let content = MenuBarContentBuilder.build(
            board: board,
            accounts: [acc],
            limit: .upToOne,
            style: .gauge,
            now: now
        )

        XCTAssertEqual(content.style, .gauge)
        XCTAssertEqual(content.gauges.count, 1)
        let gauge = content.gauges[0]
        XCTAssertEqual(gauge.provider.id, claude.id)
        XCTAssertEqual(gauge.topFraction, 0.33, accuracy: 0.001)
        XCTAssertEqual(gauge.bottomFraction, 0.27, accuracy: 0.001)
        XCTAssertNotNil(gauge.topPaceMark)
        XCTAssertNotNil(gauge.bottomPaceMark)
    }

    func testColorGaugeCalculatesSeverityBasedOnPace() {
        // Fast burning session (ahead of guideline / burning fast): 80% used when only 20% time elapsed
        let fastSession = limit("Session", used: 80, limit: 100, periodDurationMs: 5 * 3600 * 1000, resetsAt: now.addingTimeInterval(4 * 3600))
        // Healthy weekly: 10% used when 50% time elapsed
        let slowWeekly = limit("Weekly", used: 10, limit: 100, periodDurationMs: 7 * 24 * 3600 * 1000, resetsAt: now.addingTimeInterval(3.5 * 24 * 3600))

        let acc = account(claude, fastSession, slowWeekly)
        let board = PriorityBoard.make(accounts: [acc], now: now)

        let content = MenuBarContentBuilder.build(
            board: board,
            accounts: [acc],
            limit: .upToOne,
            style: .colorGauge,
            now: now
        )

        XCTAssertEqual(content.gauges.count, 1)
        let gauge = content.gauges[0]
        XCTAssertEqual(gauge.topSeverity, .critical, "Consuming faster than guideline rates as critical (red)")
        XCTAssertEqual(gauge.bottomSeverity, .normal, "Consuming slower than guideline rates as normal (blue)")
    }

    func testTemplateStatusForDifferentStyles() throws {
        let session = limit("Session", used: 50, limit: 100)
        let acc = account(claude, session)
        let board = PriorityBoard.make(accounts: [acc], now: now)

        let monochrome = MenuBarContentBuilder.build(board: board, accounts: [acc], limit: .upToOne, style: .gauge, now: now)
        let color = MenuBarContentBuilder.build(board: board, accounts: [acc], limit: .upToOne, style: .colorGauge, now: now)
        let bars = MenuBarContentBuilder.build(board: board, accounts: [acc], limit: .upToOne, style: .bars, now: now)

        let monoImage = try XCTUnwrap(MenuBarStripRenderer.image(for: monochrome))
        XCTAssertTrue(monoImage.isTemplate, "Monochrome Gauge must be template for native macOS menu-bar tinting")

        let colorImage = try XCTUnwrap(MenuBarStripRenderer.image(for: color))
        XCTAssertFalse(colorImage.isTemplate, "Color Gauge must NOT be template to preserve red/yellow/blue severity colors")

        let barsImage = try XCTUnwrap(MenuBarStripRenderer.image(for: bars))
        XCTAssertTrue(barsImage.isTemplate, "Bars must be template")
    }

    func testGaugeGeometryArcAndTickPaths() {
        let center = CGPoint(x: 9, y: 9)
        let radius: CGFloat = 8

        let topArc = MenuBarGaugeGeometry.arcPath(
            center: center,
            radius: radius,
            startDeg: MenuBarGaugeGeometry.topStartDeg,
            endDeg: MenuBarGaugeGeometry.topStartDeg + MenuBarGaugeGeometry.topSpanDeg
        )
        XCTAssertFalse(topArc.isEmpty)

        let bottomArc = MenuBarGaugeGeometry.arcPath(
            center: center,
            radius: radius,
            startDeg: MenuBarGaugeGeometry.bottomStartDeg,
            endDeg: MenuBarGaugeGeometry.bottomEndDeg
        )
        XCTAssertFalse(bottomArc.isEmpty)

        let tick = MenuBarGaugeGeometry.paceTickPath(center: center, radius: radius, angleDeg: -90, tickLength: 3.5)
        XCTAssertFalse(tick.isEmpty)
    }

    func testAccessibilityTextForGauges() {
        let session = limit("Session", used: 33, limit: 100)
        let weekly = limit("Weekly", used: 27, limit: 100)
        let acc = account(claude, session, weekly)
        let board = PriorityBoard.make(accounts: [acc], now: now)

        let content = MenuBarContentBuilder.build(board: board, accounts: [acc], limit: .upToOne, style: .gauge, now: now)
        XCTAssertTrue(content.accessibilityText.contains("Claude"))
        XCTAssertTrue(content.accessibilityText.contains("5h 33%"))
        XCTAssertTrue(content.accessibilityText.contains("7d 27%"))
    }

    func testGaugeFallbackWithoutExplicitNamesByDuration() {
        // Line without "session" or "weekly" in title, but with short (3h) and long (30d) duration
        let shortMetric = limit("Fast Pool", used: 40, limit: 100, periodDurationMs: 3 * 3600 * 1000)
        let longMetric = limit("Slow Pool", used: 60, limit: 100, periodDurationMs: 30 * 24 * 3600 * 1000)
        let acc = account(claude, shortMetric, longMetric)
        let board = PriorityBoard.make(accounts: [acc], now: now)

        let content = MenuBarContentBuilder.build(board: board, accounts: [acc], limit: .upToOne, style: .gauge, now: now)
        XCTAssertEqual(content.gauges.count, 1)
        let gauge = content.gauges[0]
        XCTAssertEqual(gauge.topFraction, 0.40, accuracy: 0.001, "Shorter duration maps to top arc")
        XCTAssertEqual(gauge.bottomFraction, 0.60, accuracy: 0.001, "Longer duration maps to bottom arc")
    }

    func testMenuBarContentIsEmptyForGauges() {
        let empty = MenuBarContent(style: .gauge, gauges: [])
        XCTAssertTrue(empty.isEmpty)

        let nonEmpty = MenuBarContent(style: .gauge, gauges: [
            MenuBarGaugeItem(id: "1", provider: claude, topFraction: 0.5, bottomFraction: 0.5)
        ])
        XCTAssertFalse(nonEmpty.isEmpty)
    }

    func testGaugeOverflowAndLimit() {
        let session = limit("Session", used: 50, limit: 100)
        let acc1 = account(claude, session)
        let acc2 = account(codex, session)
        let board = PriorityBoard.make(accounts: [acc1, acc2], now: now)

        let content = MenuBarContentBuilder.build(board: board, accounts: [acc1, acc2], limit: .upToOne, style: .gauge, now: now)
        XCTAssertEqual(content.gauges.count, 1)
        XCTAssertEqual(content.overflow, 1)
    }
}
