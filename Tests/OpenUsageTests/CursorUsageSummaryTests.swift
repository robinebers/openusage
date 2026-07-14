import XCTest
@testable import OpenUsage

final class CursorUsageSummaryMapperTests: XCTestCase {
    func testCombinesLiveEnterpriseRequestAndIndividualOnDemandShapes() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: [
                "billingCycleStart": "2026-07-01T00:00:00.000Z",
                "billingCycleEnd": "2026-08-01T00:00:00.000Z",
                "membershipType": "enterprise",
                "limitType": "team",
                "individualUsage": [
                    "plan": [
                        "enabled": true,
                        "limit": 0,
                        "autoPercentUsed": 0,
                        "apiPercentUsed": 6.25,
                        "totalPercentUsed": 6.25
                    ],
                    "onDemand": ["enabled": true, "used": 0, "limit": 25_000, "remaining": 25_000]
                ],
                "teamUsage": [
                    "onDemand": ["enabled": true, "used": 75_000, "limit": 600_000, "remaining": 525_000]
                ]
            ],
            requestUsage: [
                "gpt-4": ["numRequests": 37, "numRequestsTotal": 37, "maxRequestUsage": 750],
                "startOfMonth": "2026-07-01T00:00:00.000Z"
            ],
            planName: "Enterprise",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Enterprise")
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 37)
        XCTAssertEqual(total.limit, 750)
        XCTAssertEqual(total.format, .count(suffix: "requests"))
        XCTAssertEqual(total.resetsAt, OpenUsageISO8601.date(from: "2026-08-01T00:00:00.000Z"))
        XCTAssertEqual(total.periodDurationMs, 31 * 24 * 3_600 * 1_000)

        let requests = try XCTUnwrap(progress(mapped.lines, "Requests"))
        XCTAssertEqual(requests.used, 37)
        XCTAssertEqual(requests.limit, 750)
        XCTAssertEqual(progress(mapped.lines, "Auto usage")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "API usage")?.used, 6.25)

        let onDemand = try XCTUnwrap(progress(mapped.lines, "On-demand"))
        XCTAssertEqual(onDemand.used, 0)
        XCTAssertEqual(onDemand.limit, 250)
        XCTAssertEqual(onDemand.format, .dollars)
    }

    func testFallsBackToPooledTotalAndTeamOnDemandWhenIndividualBucketsAreMissing() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: [
                "membershipType": "team",
                "limitType": "team",
                "teamUsage": [
                    "pooled": ["enabled": true, "used": 125_000, "limit": 4_000_000, "remaining": 3_875_000],
                    "onDemand": ["enabled": true, "used": 50_000, "limit": 500_000, "remaining": 450_000]
                ]
            ],
            requestUsage: nil,
            planName: nil,
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Team")
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 1_250)
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.limit, 40_000)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 500)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.limit, 5_000)
    }

    func testFallsBackToTeamOnDemandWhenIndividualBucketIsDisabled() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: [
                "individualUsage": [
                    "plan": ["totalPercentUsed": 12],
                    "onDemand": ["enabled": false, "used": 0, "limit": 0]
                ],
                "teamUsage": [
                    "onDemand": ["enabled": true, "used": 25_000, "limit": 100_000]
                ]
            ],
            requestUsage: nil,
            planName: "Enterprise",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 250)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.limit, 1_000)
    }

    func testPositiveRemainingDeltaWinsOverReportedZeroSpend() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: [
                "individualUsage": [
                    "plan": ["totalPercentUsed": 25],
                    "onDemand": ["enabled": true, "used": 0, "limit": 100_000, "remaining": 75_000]
                ]
            ],
            requestUsage: nil,
            planName: "Enterprise",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 250)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.limit, 1_000)
    }

    func testRequestPayloadAlonePopulatesDefaultTotalAndOptionalRequests() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: nil,
            requestUsage: [
                "gpt-4": ["numRequests": 19, "maxRequestUsage": 300],
                "startOfMonth": "2026-07-01T00:00:00.000Z"
            ],
            planName: "Enterprise",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 19)
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.limit, 300)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.used, 19)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.limit, 300)
    }

    func testThrowsWhenBothFallbackPayloadsHaveNoUsableMetrics() {
        XCTAssertThrowsError(try CursorUsageSummaryMapper.map(
            summary: ["individualUsage": ["plan": ["limit": 0]]],
            requestUsage: ["gpt-4": ["maxRequestUsage": 0]],
            planName: "Enterprise",
            unavailableMessage: "Enterprise usage unavailable"
        )) { error in
            XCTAssertEqual(
                error as? CursorUsageError,
                .requestBasedUnavailable("Enterprise usage unavailable")
            )
        }
    }

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) =
            lines.first(where: { $0.label == label })
        else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }
}

@MainActor
final class CursorEnterpriseProviderTests: XCTestCase {
    func testRefreshCombinesEnterpriseMetersAndStillAppendsUsageHistory() async throws {
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-07-13T12:00:00.000Z"))
        let accessToken = makeSummaryCursorJWT(sub: "google-oauth2|enterprise-user")
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-07-13T10:00:00Z,composer-1,No,0,1000,0,100,Included
        """
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.usageURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"billingCycleStart":"1783923142900","billingCycleEnd":"1783923142900","displayThreshold":100}"#.utf8)
                )
            }
            if request.url == CursorUsageClient.planURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"Enterprise","price":"Custom"}}"#.utf8)
                )
            }
            if request.url == CursorUsageClient.usageSummaryURL {
                XCTAssertEqual(
                    request.headers["Cookie"],
                    "WorkosCursorSessionToken=enterprise-user%3A%3A\(accessToken)"
                )
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "billingCycleStart": "2026-07-01T00:00:00.000Z",
                  "billingCycleEnd": "2026-08-01T00:00:00.000Z",
                  "membershipType": "enterprise",
                  "limitType": "team",
                  "individualUsage": {
                    "plan": { "enabled": true, "autoPercentUsed": 0, "apiPercentUsed": 6.25, "totalPercentUsed": 6.25 },
                    "onDemand": { "enabled": true, "used": 0, "limit": 25000, "remaining": 25000 }
                  },
                  "teamUsage": {
                    "onDemand": { "enabled": true, "used": 75000, "limit": 600000, "remaining": 525000 }
                  }
                }
                """.utf8))
            }
            if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "gpt-4": { "numRequests": 37, "numRequestsTotal": 37, "maxRequestUsage": 750 },
                  "startOfMonth": "2026-07-01T00:00:00.000Z"
                }
                """.utf8))
            }
            if request.url.absoluteString.hasPrefix(CursorUsageClient.exportCSVURL.absoluteString) {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(csv.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: SummaryCursorSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Enterprise")
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 37)
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.limit, 750)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.limit, 250)
        XCTAssertNotNil(snapshot.lines.first { $0.label == "Usage Trend" })
        XCTAssertNotNil(snapshot.lines.first { $0.label == "Today" })
        XCTAssertEqual(snapshot.usageHistory?.series.daily.count, 1)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.date, "2026-07-13")
        XCTAssertTrue(http.requests.contains { $0.url == CursorUsageClient.usageSummaryURL })
        XCTAssertTrue(http.requests.contains { request in
            guard request.url.path == CursorUsageClient.restUsageURL.path,
                  let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            else {
                return false
            }
            return components.queryItems?.contains {
                $0.name == "user" && $0.value == "enterprise-user"
            } == true
        })
        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.hasPrefix(CursorUsageClient.exportCSVURL.absoluteString) })

        let descriptors = provider.widgetDescriptors
        let runtime = TestProviderRuntime(
            provider: provider.provider,
            descriptors: descriptors,
            snapshot: snapshot
        )
        let defaults = isolatedDefaults("default-widget")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: descriptors),
            providers: [runtime],
            cache: isolatedCache(defaults),
            defaults: defaults
        )
        await store.refreshAll()

        let totalDescriptor = try XCTUnwrap(descriptors.first { $0.id == "cursor.usage" })
        let totalData = store.data(for: totalDescriptor)
        XCTAssertTrue(DefaultLayout.metricIDs.contains("cursor.usage"))
        XCTAssertFalse(DefaultLayout.metricIDs.contains("cursor.requests"))
        XCTAssertTrue(totalData.hasData)
        XCTAssertEqual(totalData.kind, .count)
        XCTAssertEqual(totalData.used, 37)
        XCTAssertEqual(totalData.limit, 750)
        XCTAssertEqual(totalData.countSuffix, "requests")

        let onDemandDescriptor = try XCTUnwrap(descriptors.first { $0.id == "cursor.onDemand" })
        let onDemandData = store.data(for: onDemandDescriptor)
        XCTAssertTrue(onDemandData.hasData)
        XCTAssertEqual(onDemandData.kind, .dollars)
        XCTAssertEqual(onDemandData.used, 0)
        XCTAssertEqual(onDemandData.limit, 250)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.CursorEnterprise.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }
}

private func makeSummaryCursorJWT(sub: String, exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class SummaryCursorSQLite: SQLiteAccessing, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) {
            return value
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
