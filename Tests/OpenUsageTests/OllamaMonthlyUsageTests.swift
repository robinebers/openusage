import XCTest
@testable import OpenUsage

/// Current Ollama plans: a monthly dollar allowance from `GET /api/balance` (regression for #1358).
@MainActor
final class OllamaMonthlyUsageTests: XCTestCase {
    /// From https://docs.ollama.com/api/balance.
    private let creditsBody = Data(#"""
    {"included":{"balance_usd":72.5,"allowance_usd":100,
                 "period":{"from":"2026-09-15T09:30:00Z","until":"2026-10-15T09:30:00Z"}},
     "purchased":{"balance_usd":25}}
    """#.utf8)
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testCurrentPlanMapsMonthlyCreditsAndPurchasedCredits() throws {
        let mapped = try OllamaUsageMapper.map(
            balanceBody: creditsBody,
            accountBody: Data(#"{"Plan":"pro"}"#.utf8)
        )

        XCTAssertEqual(mapped.plan, .named("Pro"))
        XCTAssertEqual(mapped.lines, [
            .progress(label: "Monthly", used: 27.5, limit: 100, format: .dollars,
                      resetsAt: OpenUsageISO8601.date(from: "2026-10-15T09:30:00Z"),
                      periodDurationMs: 30 * 24 * 60 * 60 * 1000),
            .values(label: "Purchased Credits", values: [MetricValue(number: 25, kind: .dollars)])
        ])
    }

    func testAllLabelsMatchWidgetDescriptorsInDeclarationOrder() throws {
        let legacy = try OllamaUsageMapper.balanceLines(Data(#"""
        {"included":{"session":{"remaining_percent":90},"weekly":{"remaining_percent":80},
                     "balance_usd":10,"allowance_usd":60},"purchased":{"balance_usd":0}}
        """#.utf8))

        XCTAssertEqual(legacy.map(\.label), OllamaProvider().widgetDescriptors.map(\.metricLabel))
        XCTAssertEqual(legacy.map(\.label), ["Session", "Weekly", "Monthly", "Purchased Credits"])
    }

    func testUnusedAndOverspentAllowancesStayWithinTheMeter() throws {
        let unused = try OllamaUsageMapper.balanceLines(Data(#"{"included":{"balance_usd":60,"allowance_usd":60}}"#.utf8))
        let overspent = try OllamaUsageMapper.balanceLines(Data(#"{"included":{"balance_usd":-5,"allowance_usd":60}}"#.utf8))

        XCTAssertEqual(unused, [.progress(label: "Monthly", used: 0, limit: 60, format: .dollars)])
        XCTAssertEqual(overspent, [.progress(label: "Monthly", used: 60, limit: 60, format: .dollars)])
    }

    func testMissingOrUnusableAllowanceDoesNotInventAMeter() throws {
        for included in [#""balance_usd":10"#, #""allowance_usd":60"#, #""balance_usd":10,"allowance_usd":0"#,
                         #""balance_usd":"x","allowance_usd":60"#] {
            let body = Data("{\"included\":{\"weekly\":{\"remaining_percent\":50},\(included)}}".utf8)
            XCTAssertEqual(try OllamaUsageMapper.balanceLines(body).map(\.label), ["Weekly"], included)
        }
    }

    func testMonthlyCreditsReachDashboardDataAndBothLocalAPIs() async throws {
        let provider = OllamaProvider()
        let registry = WidgetRegistry.from([provider])
        let snapshot = ProviderSnapshot(
            providerID: "ollama", displayName: "Ollama", plan: "Pro",
            lines: try OllamaUsageMapper.balanceLines(creditsBody), refreshedAt: fetchedAt
        )
        let runtime = TestProviderRuntime(
            provider: provider.provider, descriptors: provider.widgetDescriptors, snapshot: snapshot
        )
        let defaults = makeDefaults()
        let store = WidgetDataStore(
            registry: registry, providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )
        await store.refreshAll()
        let monthly = store.data(for: try XCTUnwrap(registry.descriptor(id: "ollama.monthly")))
        XCTAssertTrue(monthly.hasData)
        XCTAssertEqual(monthly.used, 27.5, accuracy: 0.0001)
        XCTAssertEqual(monthly.limit, 100)
        let purchased = store.data(for: try XCTUnwrap(registry.descriptor(id: "ollama.purchasedCredits")))
        XCTAssertTrue(purchased.hasData)

        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["ollama"], knownIDs: ["ollama"], snapshots: ["ollama": snapshot],
            limitDescriptors: registry.limitDescriptorsByProvider, generatedAt: fetchedAt
        )
        let usageBody = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state).body)
        let usage = try XCTUnwrap(JSONSerialization.jsonObject(with: usageBody) as? [[String: Any]])
        let usageLine = try XCTUnwrap((usage.first?["lines"] as? [[String: Any]])?.first { $0["label"] as? String == "Monthly" })
        XCTAssertEqual(try XCTUnwrap(usageLine["used"] as? Double), 27.5, accuracy: 0.0001)
        XCTAssertEqual(usageLine["limit"] as? Double, 100)

        let limitsBody = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let limits = try XCTUnwrap(JSONSerialization.jsonObject(with: limitsBody) as? [String: Any])
        let account = try XCTUnwrap((limits["providers"] as? [String: Any])?["ollama"] as? [String: Any])
        let resources = try XCTUnwrap(account["resources"] as? [String: Any])
        XCTAssertEqual(Set(resources.keys), ["monthly", "purchasedCredits"])
        let resource = try XCTUnwrap(resources["monthly"] as? [String: Any])
        XCTAssertEqual(resource["unit"] as? String, "usd")
        XCTAssertEqual(try XCTUnwrap(resource["used"] as? Double), 27.5, accuracy: 0.0001)
        XCTAssertEqual(resource["limit"] as? Double, 100)
        XCTAssertEqual(try XCTUnwrap(resource["utilization"] as? Double), 0.275, accuracy: 0.0001)
        XCTAssertNotNil(resource["resetsAt"])
        let balance = try XCTUnwrap(resources["purchasedCredits"] as? [String: Any])
        XCTAssertEqual(balance["unit"] as? String, "usd")
    }

    func testDefaultPlacementOnFreshInstallAndUpgrade() throws {
        let registry = WidgetRegistry.from([OllamaProvider()])
        let defaults = makeDefaults()
        let fresh = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(fresh.placed.map(\.descriptorID), [
            "ollama.session", "ollama.weekly", "ollama.monthly", "ollama.purchasedCredits"
        ])
        XCTAssertFalse(fresh.expandedMetricIDs.contains("ollama.monthly"))
        XCTAssertTrue(fresh.expandedMetricIDs.contains("ollama.purchasedCredits"))
        XCTAssertEqual(fresh.pinnedMetricIDs, ["ollama.session", "ollama.weekly", "ollama.monthly"])

        // A customized layout from before this change drops the removed Last 4 Weeks row, receives
        // Purchased Credits once, and keeps the user's own pins.
        defaults.set(try JSONEncoder().encode([
            PlacedWidget(descriptorID: "ollama.session"), PlacedWidget(descriptorID: "ollama.last4Weeks")
        ]), forKey: "layout")
        defaults.set(try JSONEncoder().encode([
            "ollama.session", "ollama.weekly", "ollama.monthly", "ollama.last4Weeks"
        ]), forKey: "layout.seededDefaults")
        defaults.set(["ollama.session"], forKey: "layout.menuBarPins")
        let upgraded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(upgraded.placed.contains { $0.descriptorID == "ollama.last4Weeks" })
        XCTAssertTrue(upgraded.isMetricEnabled("ollama.purchasedCredits"))
        XCTAssertFalse(upgraded.isMetricEnabled("ollama.monthly"))
        XCTAssertEqual(upgraded.pinnedMetricIDs, ["ollama.session"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.OllamaMonthly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
