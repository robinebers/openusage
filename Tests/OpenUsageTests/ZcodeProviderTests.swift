import XCTest
@testable import OpenUsage

/// Z.ai combines quota meters and local Zcode usage without creating a second provider card.
@MainActor
final class ZAIZcodeUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let databasePath = "~/.zcode/cli/db/db.sqlite"

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "glm-5.3": ModelRates(
                inputPerMillion: 1, outputPerMillion: 4,
                cacheWritePerMillion: 1, cacheReadPerMillion: 0.25
            )
        ]),
        secondary: PricingCatalog()
    )

    private var usageDatabase: String {
        "[" + [
            zcodeRow("2026-07-12T11:00:00.000Z", "glm-5.3", input: 1000, output: 500),
            zcodeRow("2026-07-11T11:00:00.000Z", "glm-5.3", input: 2000, output: 1000)
        ].joined(separator: ",") + "]"
    }

    private func provider(
        data: [String: String] = [:],
        failing: Set<String> = [],
        databasePaths: [String]? = nil,
        key: String? = nil,
        quotaStatus: Int = 200
    ) -> ZAIProvider {
        let now = self.now
        let pricing = self.pricing
        return ZAIProvider(
            usageScanner: ZcodeUsageScanner(
                sqlite: ZcodeFakeSQLite(data: data, failing: failing),
                databasePaths: { databasePaths ?? Array(data.keys) }
            ),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(
                key.map { ["ZAI_API_KEY": $0] } ?? [:]
            )),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(statusCode: quotaStatus, headers: [:], body: Data(
                        #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":15}]}}"#.utf8
                    ))
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))
            }),
            pricing: { pricing },
            now: { now }
        )
    }

    func testHasLocalCredentialsViaLocalUsageButNotForEmptyDatabase() async {
        let detected = await provider(data: [databasePath: usageDatabase]).hasLocalCredentials()
        XCTAssertTrue(detected)
        let empty = await provider(data: [databasePath: "[]"]).hasLocalCredentials()
        XCTAssertFalse(empty)
        let absent = await provider().hasLocalCredentials()
        XCTAssertFalse(absent)
    }

    func testLocalUsageBacksSpendAndTrend() async {
        let snapshot = await provider(data: [databasePath: usageDatabase]).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Yesterday"))
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testQuotaAndLocalUsageShareOneCard() async {
        let snapshot = await provider(data: [databasePath: usageDatabase], key: "test-key").refresh()
        XCTAssertEqual(snapshot.providerID, "zai")
        XCTAssertNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.usageHistory)
        let ids = ProviderCatalog.make().map { $0.provider.id }
        XCTAssertEqual(ids.filter { $0 == "zai" }.count, 1)
        XCTAssertFalse(ids.contains("zcode"))
    }

    func testQuotaFailureKeepsLocalSpendWithWarning() async {
        let snapshot = await provider(data: [databasePath: usageDatabase], key: "test-key", quotaStatus: 401).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testLocalHistoryUsesSharedRenderingAndSummaryCapability() async throws {
        let runtime = provider(data: [databasePath: usageDatabase])
        let snapshot = await runtime.refresh()
        let history = try XCTUnwrap(snapshot.usageHistory)
        let descriptor = try XCTUnwrap(runtime.widgetDescriptors.compactMap(\.historyResource).first)
        XCTAssertEqual(descriptor.scope, .machineLocal)
        let rendered = UsageHistorySnapshotRenderer.render(local: snapshot, history: history,
                                                            descriptor: descriptor, now: now)
        guard case .values(_, let values, _, _, _, let breakdown)? = rendered.line(label: "Today"),
              case .chart(_, let points, let note)? = rendered.line(label: "Usage Trend") else {
            return XCTFail("expected rendered local history")
        }
        XCTAssertEqual(values.first?.number, 0.003)
        XCTAssertEqual(values.last?.number, 1500)
        XCTAssertEqual(points.reduce(0) { $0 + $1.value }, 4500)
        XCTAssertTrue(breakdown?.sourceNote.hasPrefix("Across your Macs") == true)
        XCTAssertTrue(note?.hasPrefix("Across your Macs") == true)
        let defaults = UserDefaults(suiteName: "zai-local-\(UUID().uuidString)")!
        let layout = LayoutStore(registry: WidgetRegistry.from([runtime]), defaults: defaults)
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["zai"])
    }

    func testDatabaseFailureKeepsQuotaWithWarning() async {
        let snapshot = await provider(data: [databasePath: usageDatabase], failing: [databasePath], key: "test-key").refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testSnapshotContributesToTotalSpendForEveryPeriod() async {
        let runtime = provider(data: [databasePath: usageDatabase])
        let snapshot = await runtime.refresh()
        for (period, tokens, dollars) in [(TotalSpendPeriod.today, 1500.0, 0.003),
                                         (.yesterday, 3000.0, 0.006), (.last30, 4500.0, 0.009)] {
            let total = TotalSpendAggregator.total(for: period, providers: [runtime.provider],
                                                  snapshots: [runtime.provider.id: snapshot])
            XCTAssertEqual(total.slices.map(\.provider.id), ["zai"])
            XCTAssertEqual(total.totalTokens, tokens)
            XCTAssertEqual(total.totalUSD, dollars, accuracy: 1e-9)
            XCTAssertTrue(total.isEstimated)
        }
    }

    func testSpendTilesAreMarkedEstimated() async {
        let snapshot = await provider(data: [databasePath: usageDatabase]).refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        // Tokens are measured; the dollars are priced locally from token counts, so they carry the ⓘ.
        XCTAssertTrue(values.contains(where: \.estimated))
        XCTAssertEqual(values.first?.number ?? 0, 0.001 + 0.002, accuracy: 1e-9)
    }

    func testRefreshErrorsWhenNoDatabaseFound() async {
        let snapshot = await provider().refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshErrorsWhenDatabaseUnreadable() async {
        let snapshot = await provider(
            data: [databasePath: usageDatabase],
            failing: [databasePath],
            databasePaths: [databasePath]
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testEmptyDatabaseShowsNoDataRatherThanAnError() async {
        let snapshot = await provider(data: [databasePath: "[]"]).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.noUsageData.label)
    }
}
