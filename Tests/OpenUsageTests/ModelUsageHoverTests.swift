import XCTest
@testable import OpenUsage

@MainActor
final class ModelUsageHoverTests: XCTestCase {
    func testValuesLineCodableRoundTripsModelBreakdown() throws {
        let breakdown = sampleBreakdown()
        let line = MetricLine.values(
            label: "Today",
            values: [MetricValue(number: 3, kind: .dollars), MetricValue(number: 300, kind: .count, label: "tokens")],
            modelBreakdown: breakdown
        )

        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(MetricLine.self, from: data)

        XCTAssertEqual(decoded, line)
    }

    func testDataStoreResolvesModelBreakdownOntoSpendRow() {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.spendTiles(provider: provider).first { $0.id == "claude.today" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeDefaults("resolve")
        )
        store.snapshots[provider.id] = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3, kind: .dollars, estimated: true),
                        MetricValue(number: 300, kind: .count, label: "tokens")
                    ],
                    modelBreakdown: sampleBreakdown()
                )
            ]
        )

        let data = store.data(for: descriptor)

        XCTAssertTrue(data.hasModelBreakdown)
        XCTAssertEqual(data.modelBreakdown?.models.map(\.model), ["alpha", "beta"])
        XCTAssertEqual(data.modelBreakdown?.sourceNote, "From test logs")
    }

    func testDataStoreAllowsSingleModelBreakdown() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.spendTiles(provider: provider).first { $0.id == "codex.today" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeDefaults("single-model")
        )
        store.snapshots[provider.id] = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3, kind: .dollars, estimated: true),
                        MetricValue(number: 300, kind: .count, label: "tokens")
                    ],
                    modelBreakdown: ModelUsageBreakdown(
                        totalTokens: 300,
                        totalCostUSD: 3,
                        models: [ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)],
                        sourceNote: "From Codex test logs"
                    )
                )
            ]
        )

        let data = store.data(for: descriptor)

        XCTAssertTrue(data.hasModelBreakdown)
        XCTAssertEqual(data.modelBreakdown?.models.map(\.model), ["gpt-5.5"])
    }

    func testWholePercentsAlwaysSumToOneHundred() {
        // Independent rounding would print 33 / 33 / 33 = 99; the largest remainder takes the leftover point.
        XCTAssertEqual(ModelUsageDetail.wholePercents([1.0 / 3, 1.0 / 3, 1.0 / 3]), [34, 33, 33])
        // Independent rounding would print 62 + 34 + 5 = 101 (0.045 rounds up); flooring plus
        // remainder distribution keeps the column at exactly 100.
        XCTAssertEqual(ModelUsageDetail.wholePercents([0.62, 0.335, 0.045]), [62, 34, 4])
        XCTAssertEqual(ModelUsageDetail.wholePercents([1.0]), [100])
        XCTAssertEqual(ModelUsageDetail.wholePercents([0, 0]), [0, 0], "an empty period stays all zero")

        for shares in [[0.005, 0.005, 0.99], [0.2, 0.2, 0.2, 0.2, 0.2], [0.617, 0.337, 0.046]] {
            XCTAssertEqual(ModelUsageDetail.wholePercents(shares).reduce(0, +), 100)
        }
    }

    func testSharesUseCostWhenEveryModelIsPriced() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 10, costUSD: 3),
            ModelUsageEntry(model: "beta", totalTokens: 90, costUSD: 1)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0.75, 0.25])
    }

    func testSharesUseTokensForEveryModelWhenOneIsUnpriced() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 25, costUSD: 9),
            ModelUsageEntry(model: "beta", totalTokens: 75, costUSD: nil)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0.25, 0.75])
    }

    func testSharesAreZeroWhenThereIsNoCostOrTokenTotal() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 0, costUSD: nil),
            ModelUsageEntry(model: "beta", totalTokens: 0, costUSD: nil)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0, 0])
    }

    func testHoverPopoverStateOpensThenClosesAroundBothRegions() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        XCTAssertFalse(state.isPresented)

        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "opens after the reveal dwell while the row is hovered")

        state.inlineHover(false)
        state.detailHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "stays open while the cursor is inside the popover")

        state.detailHover(false)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.isPresented, "closes once the cursor has left both the row and the popover")
    }

    func testHoverPopoverStateQuickPassDoesNotOpen() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(60), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        state.inlineHover(false)
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(state.isPresented, "a quick pass over the row never opens the popover")
    }

    func testHoverPopoverStateDismissForcesClosed() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented)

        state.dismiss()
        XCTAssertFalse(state.isPresented, "teardown closes it immediately")
    }

    private func sampleBreakdown() -> ModelUsageBreakdown {
        ModelUsageBreakdown(
            totalTokens: 300,
            totalCostUSD: 3,
            models: [
                ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 1),
                ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 2)
            ],
            sourceNote: "From test logs"
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.ModelUsageHover.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
