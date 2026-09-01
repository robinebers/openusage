import XCTest
@testable import OpenUsage

/// Covers `MenuBarContentBuilder`: it resolves pinned provider groups into Text groups (order, labels,
/// and values preserved) and Bars entries (bounded metrics only, first four in order), and reports empty
/// when nothing is pinned.
@MainActor
final class MenuBarContentTests: XCTestCase {
    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testSameMetricAcrossAccountCardsStacksInCardOrder() {
        let personal = percent("codex.weekly", "Weekly", 31)
        let work = percent("codex@work.weekly", "Weekly", 72)

        let content = MenuBarContentBuilder.build(
            groups: [group("codex", personal), group("codex@work", work)],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.count, 1)
        XCTAssertEqual(content.groups[0].displayName, "Codex")
        XCTAssertEqual(
            content.groups[0].metrics.map(\.id),
            ["codex.weekly", "codex@work.weekly"]
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["31%", "72%"])
        XCTAssertEqual(
            content.accessibilityText,
            "Codex accounts: CODEX Weekly 31%, CODEX@WORK Weekly 72%"
        )

        let reordered = MenuBarContentBuilder.build(
            groups: [group("codex@work", work), group("codex", personal)],
            data: { $0.sample }
        )
        XCTAssertEqual(
            reordered.groups[0].metrics.map(\.id),
            ["codex@work.weekly", "codex.weekly"]
        )
    }

    func testDifferentSingleMetricsAcrossAccountCardsStillStack() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("codex", percent("codex.weekly", "Weekly", 31)),
                group("codex@work", percent("codex@work.session", "Session", 72)),
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.count, 1)
        XCTAssertEqual(
            content.groups[0].metrics.map(\.id),
            ["codex.weekly", "codex@work.session"]
        )
        XCTAssertEqual(
            content.accessibilityText,
            "Codex accounts: CODEX Weekly 31%, CODEX@WORK Session 72%"
        )
    }

    func testAccountCardsWithTwoPinnedMetricsEachKeepSeparateSegments() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("codex", percent("codex.session", "Session", 21), percent("codex.weekly", "Weekly", 31)),
                group(
                    "codex@work",
                    percent("codex@work.session", "Session", 62),
                    percent("codex@work.weekly", "Weekly", 72)
                ),
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["codex", "codex@work"])
        XCTAssertEqual(content.groups.map { $0.metrics.count }, [2, 2])
    }

    func testBarsIncludeBoundedMetricsAndDropUnbounded() {
        // A bounded dollar metric has a fill, so it belongs in Bars. An unbounded value (raw spend,
        // no limit) has no fill and is dropped.
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                percent("a.pct", "Pct", 40),
                boundedDollars("a.credits", "Credits", used: 12000, limit: 18000),
                unbounded("a.spend", "Spend"))],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.pct", "a.credits", "a.spend"])  // Text: all
        XCTAssertEqual(content.bars.map(\.id), ["a.pct", "a.credits"])                          // Bars: bounded only
    }

    func testBarsCappedToFourInOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "M1", 10), percent("a.m2", "M2", 20)),
                group("b", percent("b.m1", "M1", 30), percent("b.m2", "M2", 40)),
                group("c", percent("c.m1", "M1", 50), percent("c.m2", "M2", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.bars.count, 4)
        XCTAssertEqual(content.bars.map(\.id), ["a.m1", "a.m2", "b.m1", "b.m2"])
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

        XCTAssertEqual(content.groups.map(\.providerID), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
        XCTAssertEqual(content.bars.map(\.id), ["a.live"])
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
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testAccessibilityTextUsesTheResolvedTitle() {
        // The VoiceOver summary is a human-facing name, so it goes through the caller's resolver
        // (the account registry) instead of the baked provider name.
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41))],
            data: { $0.sample },
            title: { _ in "Claude Team" }
        )
        XCTAssertEqual(content.accessibilityText, "Claude Team Session 41%")
    }

    func testTrayLabelsShortenLongTimeWindows() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["T", "M"])
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

    func testUnboundedNumbersAreCompacted() {
        // Standard compact notation for big numbers; values shown in full drop their decimals.
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                unbounded("a.big", "Big", 12923),         // → $12.9K
                unbounded("a.small", "Small", 129.81))],  // → $130 (no decimals)
            data: { $0.sample }
        )

        let big = content.groups[0].metrics[0].value
        XCTAssertTrue(big.hasSuffix("K"), "expected compact thousands, got \(big)")
        XCTAssertFalse(big.contains("923"), "expected the raw number to be compacted away, got \(big)")
        XCTAssertEqual(content.groups[0].metrics[1].value, "$130")
    }

    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(
            id: providerID,
            displayName: providerID.uppercased(),
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
