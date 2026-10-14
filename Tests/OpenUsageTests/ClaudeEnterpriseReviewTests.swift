import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeEnterpriseReviewTests: XCTestCase {
    func testUncappedEnterpriseSpendPreservesZeroWithoutChangingConsumerIdleBehavior() throws {
        for limit in ["", ",\"monthly_limit\":0"] {
            let response = HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data("{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":0\(limit)}}".utf8)
            )
            let enterprise = try ClaudeUsageMapper.mapUsageResponse(
                response, credentials: ClaudeOAuth(subscriptionType: "enterprise")
            )
            guard case .values(_, let values, _, _, _, _, let title)? =
                    enterprise.lines.first(where: { $0.label == "Extra usage spent" })
            else {
                XCTFail("Zero is a valid uncapped Enterprise billing total")
                continue
            }
            XCTAssertEqual(title, "Spend")
            XCTAssertEqual(values, [MetricValue(number: 0, kind: .dollars)])

            let consumer = try ClaudeUsageMapper.mapUsageResponse(
                response, credentials: ClaudeOAuth(subscriptionType: "max")
            )
            XCTAssertFalse(consumer.lines.contains { $0.label == "Extra usage spent" })
        }
    }

    func testEnterpriseUpgradeUsesLiveProfileForPrimaryAndIdentityBoundCards() async {
        for identity in [nil, "account|organization"] as [String?] {
            let http = RoutingHTTPClient { request in
                switch request.url.path {
                case "/api/oauth/usage": return Self.usage(usedCredits: 500)
                case "/api/oauth/profile": return Self.profile(type: identity == nil ? "enterprise" : "claude_enterprise")
                default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }
            let provider = makeProvider(storedType: "max", http: http, identity: identity)
            for _ in 0..<2 {
                let snapshot = await provider.refresh()
                XCTAssertEqual(snapshot.plan, "Enterprise")
                XCTAssertFalse(snapshot.lines.contains { $0.label == "Session" })
                guard case .values(_, let values, _, _, _, _, let title)? =
                        snapshot.lines.first(where: { $0.label == "Extra usage spent" })
                else {
                    XCTFail("The live Enterprise plan must emit its monthly Spend total")
                    continue
                }
                XCTAssertEqual(title, "Spend")
                XCTAssertEqual(values.first?.number, 5)
            }
            XCTAssertEqual(http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 1)
        }
    }

    func testLiveConsumerPlanOverridesStoredEnterpriseClassification() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage": return Self.usage(usedCredits: 500)
            case "/api/oauth/profile": return Self.profile(type: "claude_max")
            default: return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let snapshot = await makeProvider(storedType: "enterprise", http: http).refresh()
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Session" })
        guard case .values(_, _, _, _, _, _, let title)? =
                snapshot.lines.first(where: { $0.label == "Extra usage spent" })
        else { return XCTFail("Expected consumer extra usage") }
        XCTAssertNil(title)
    }

    func testEnterpriseDefaultPinsCanBeReplacedWithSpendAndSurviveReload() async throws {
        let provider = ClaudeProvider.makeProvider()
        let descriptors = ClaudeProvider().widgetDescriptors
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            Self.usage(usedCredits: 500), credentials: ClaudeOAuth(subscriptionType: "enterprise")
        )
        let runtime = TestProviderRuntime(
            provider: provider, descriptors: descriptors,
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: mapped.lines)
        )
        let defaults = makeDefaults()
        let dataStore = WidgetDataStore(
            registry: registry, providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await dataStore.refreshAll()
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        layout.bindMetricVisibility(to: dataStore)
        XCTAssertEqual(layout.pinnedMetricIDs, ["claude.session", "claude.weekly"])
        XCTAssertTrue(layout.canPin("claude.extra"))
        layout.setPinned(true, for: "claude.extra")
        XCTAssertEqual(layout.pinnedMetricIDs, ["claude.extra"])
        let content = MenuBarContentBuilder.build(groups: layout.pinnedGroups, data: { dataStore.data(for: $0) })
        XCTAssertEqual(content.groups.first?.metrics.map(\.id), ["claude.extra"])
        XCTAssertEqual(content.groups.first?.metrics.first?.value, "$5")

        let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(reloaded.pinnedMetricIDs, ["claude.extra"])
        XCTAssertTrue(layout.undo())
        XCTAssertEqual(layout.pinnedMetricIDs, ["claude.session", "claude.weekly"])
    }

    func testOrdinaryMissingDataPinsStillEnforceTheCap() async {
        let provider = ClaudeProvider.makeProvider()
        let descriptors = ClaudeProvider().widgetDescriptors
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let runtime = TestProviderRuntime(
            provider: provider, descriptors: descriptors,
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let defaults = makeDefaults()
        let dataStore = WidgetDataStore(
            registry: registry, providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await dataStore.refreshAll()
        let layout = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout",
            defaultPinnedMetricIDs: ["claude.today", "claude.last30"]
        )
        layout.bindMetricVisibility(to: dataStore)
        XCTAssertFalse(layout.canPin("claude.extra"))
        layout.setPinned(true, for: "claude.extra")
        XCTAssertEqual(layout.pinnedMetricIDs, ["claude.today", "claude.last30"])
    }

    private func makeProvider(storedType: String, http: RoutingHTTPClient, identity: String? = nil) -> ClaudeProvider {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentials = """
        {"claudeAiOauth":{"accessToken":"token-a","expiresAt":4102444800000,"subscriptionType":"\(storedType)","scopes":["user:profile"]}}
        """
        return ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles(["/tmp/claude/.credentials.json": credentials]),
                keychain: FakeKeychain(), expectedIdentityKey: identity, now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now }, pricing: { TestPricing.bundled }
        )
    }

    private nonisolated static func usage(usedCredits: Int = 0) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data("""
            {"five_hour":{"utilization":42},"extra_usage":{"is_enabled":true,"used_credits":\(usedCredits)}}
            """.utf8)
        )
    }

    private nonisolated static func profile(type: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data("""
            {"account":{"uuid":"account"},"organization":{"uuid":"organization","organization_type":"\(type)"}}
            """.utf8)
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OpenUsageTests.EnterpriseReview.\(UUID().uuidString)")!
    }
}
