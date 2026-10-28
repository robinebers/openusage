import XCTest
@testable import OpenUsage

/// Covers `MenuBarContentBuilder`: it resolves pinned provider groups into strip groups (order, labels,
/// and values preserved), and reports empty when nothing is pinned.
@MainActor
final class MenuBarContentTests: XCTestCase {
    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.provider.id), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testStripKeepsBoundedAndUnboundedMetrics() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                percent("a.pct", "Pct", 40),
                boundedDollars("a.credits", "Credits", used: 12000, limit: 18000),
                unbounded("a.spend", "Spend"))],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.pct", "a.credits", "a.spend"])
    }

    func testNoDataMetricsDropFromStrip() {
        // The strip is dynamic: a pinned metric without data vanishes instead of rendering "—", and
        // the surviving pin renders alone (full size). A provider whose pins all lack data
        // contributes no icon at all.
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly")),
                group("b", noDataPercent("b.nd", "ND"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.provider.id), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
    }

    func testAllPinsWithoutDataFallBackToAppIcon() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "ND"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "Claude Session 41%, Weekly 12%")
    }

    func testTodayReadsT() {
        let content = MenuBarContentBuilder.build(groups: [group("a", percent("a.today", "Today", 5))], data: { $0.sample })
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["T"])
    }

    func testBoundedTrayValuesStayUnitAware() {
        // Percent meters still read as percentages, while bounded dollars/counts keep their natural
        // unit in the strip instead of collapsing to "used / limit" percentages.
        let usage = percent("a.usage", "Usage", 67)
        let credits = boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)
        let requests = boundedCount("a.requests", "Requests", used: 412, limit: 500)
        let spend = unbounded("a.spend", "Spend")   // unbounded $42
        let content = MenuBarContentBuilder.build(groups: [group("a", usage, credits, requests, spend)], data: { $0.sample })

        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["67%", "$12K", "412", "$42"])
    }

    // Compact-notation rules for tray values (abbreviation, decimal rounding) are pinned exactly in
    // MetricFormatterTests — the strip only relays MetricFormatter output.

    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(id: providerID, kind: providerID == "a" ? .claude : .codex)
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        let parts = id.split(separator: ".").map(String.init)
        return WidgetDescriptor(
            provider: Provider(id: parts[0], kind: parts[0] == "a" ? .claude : .codex),
            key: parts[1],
            metricLabel: label,
            sample: sample
        )
    }
}
