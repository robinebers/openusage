import XCTest
@testable import OpenUsage

final class UsageHistoryAggregatorTests: XCTestCase {
    func testAggregationAddsMachineLocalHistoryAndIgnoresAccountWideHistory() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [],
            usageHistory: history(tokens: 100, cost: 1, model: "Opus", unknown: ["unknown-a"])
        )
        let cursor = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [],
            usageHistory: history(tokens: 9_000, cost: 90, model: "Cursor Model")
        )
        let oldDuplicate = document(
            deviceID: "peer-a",
            updatedAt: 100,
            providers: ["claude": history(tokens: 9_999, cost: 99, model: "Opus")]
        )
        let newestDuplicate = document(
            deviceID: "peer-a",
            updatedAt: 200,
            providers: [
                "claude": history(tokens: 200, cost: 2, model: "opus", unknown: ["unknown-b"]),
                "cursor": history(tokens: 9_000, cost: 90, model: "Cursor Model")
            ]
        )
        let secondPeer = document(
            deviceID: "peer-b",
            updatedAt: 150,
            providers: ["claude": history(tokens: 50, cost: nil, model: "Sonnet")]
        )

        let merged = UsageHistoryAggregator.merged(
            localSnapshots: ["claude": local, "cursor": cursor],
            peerDocuments: [oldDuplicate, newestDuplicate, secondPeer],
            descriptors: [
                "claude": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs"),
                "cursor": UsageHistoryDescriptor(scope: .accountWide, estimatedCost: true, sourceNote: "export")
            ],
            now: localDay(2026, 7, 13)
        )

        let claude = try XCTUnwrap(merged["claude"])
        XCTAssertEqual(claude.series.daily, [
            DailyUsageEntry(date: "2026-07-13", totalTokens: 350, costUSD: 3)
        ])
        XCTAssertEqual(claude.modelUsage?.daily[0].models.map(\.model), ["Opus", "Sonnet"])
        XCTAssertEqual(claude.modelUsage?.daily[0].models.first?.totalTokens, 300)
        XCTAssertEqual(claude.unknownModelsByDay["2026-07-13"], ["unknown-a", "unknown-b"])
        XCTAssertNil(merged["cursor"], "account-wide Cursor history must never be added across Macs")
    }

    func testAggregationExcludesRowsOutsideScannerWindow() throws {
        let peerHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: 10, costUSD: 1),
                DailyUsageEntry(date: "2026-06-13", totalTokens: 20, costUSD: 2),
                DailyUsageEntry(date: "2026-06-12", totalTokens: 9_000, costUSD: 90)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(model: "Current", totalTokens: 10, costUSD: 1)
                ]),
                DailyModelUsageEntry(date: "2026-06-12", models: [
                    ModelUsageEntry(model: "Stale", totalTokens: 9_000, costUSD: 90)
                ])
            ]),
            unknownModelsByDay: [
                "2026-07-13": ["current-unknown"],
                "2026-06-12": ["stale-unknown"]
            ]
        )

        let merged = UsageHistoryAggregator.merged(
            localSnapshots: [:],
            peerDocuments: [document(deviceID: "peer", updatedAt: 100, providers: ["claude": peerHistory])],
            descriptors: [
                "claude": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
            ],
            now: localDay(2026, 7, 13)
        )

        let claude = try XCTUnwrap(merged["claude"])
        XCTAssertEqual(claude.series.daily.map(\.date), ["2026-07-13", "2026-06-13"])
        XCTAssertEqual(claude.series.daily.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(claude.modelUsage?.daily.flatMap(\.models).map(\.model), ["Current"])
        XCTAssertEqual(claude.unknownModelsByDay, ["2026-07-13": ["current-unknown"]])
    }

    func testRendererReplacesOnlySpendRowsAndKeepsLocalState() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Max",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 1, kind: .dollars)]),
                .badge(label: "Local notice", text: "Keep me", colorHex: "#123456")
            ],
            refreshedAt: Date(timeIntervalSince1970: 500),
            warning: "Local warning"
        )
        let combined = history(tokens: 350, cost: 3, model: "Opus")

        let rendered = UsageHistorySnapshotRenderer.render(
            local: local,
            history: combined,
            descriptor: UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "From logs"),
            now: localDay(2026, 7, 13)
        )

        XCTAssertEqual(rendered.plan, "Max")
        XCTAssertEqual(rendered.warning, "Local warning")
        XCTAssertEqual(rendered.refreshedAt, local.refreshedAt)
        XCTAssertEqual(rendered.line(label: "Session"), local.line(label: "Session"))
        XCTAssertEqual(rendered.line(label: "Local notice"), local.line(label: "Local notice"))
        guard case .values(_, let values, _, _, _, let breakdown) = rendered.line(label: "Today") else {
            return XCTFail("Today should be rebuilt as a values row")
        }
        XCTAssertEqual(values.map(\.number), [3, 350])
        XCTAssertEqual(breakdown?.totalTokens, 350)
        XCTAssertEqual(breakdown?.models.map(\.model), ["Opus"])
        XCTAssertTrue(rendered.lines.contains { $0.label == "Usage Trend" })
    }

    private func history(
        tokens: Int,
        cost: Double?,
        model: String,
        unknown: Set<String> = []
    ) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: tokens, costUSD: cost)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(model: model, totalTokens: tokens, costUSD: cost)
                ])
            ]),
            unknownModelsByDay: unknown.isEmpty ? [:] : ["2026-07-13": unknown]
        )
    }

    private func document(
        deviceID: String,
        updatedAt: TimeInterval,
        providers: [String: ProviderUsageHistory]
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceID,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            providers: providers
        )
    }

    private func localDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
