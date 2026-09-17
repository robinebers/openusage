import XCTest
@testable import OpenUsage

@MainActor
final class OllamaMonthlyUsageTests: XCTestCase {
    private let monthlyBody = Data(#"{"limits":{"monthly":{"usage":0.053}},"activity":{"cost":"0"}}"#.utf8)
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreePlanWithOnlyMonthlyLimitMapsUsageAndSpend() throws {
        let mapped = try OllamaUsageMapper.map(
            usageBody: monthlyBody,
            accountBody: Data(#"{"Plan":"free"}"#.utf8)
        )

        XCTAssertEqual(mapped.plan, "Free")
        XCTAssertEqual(mapped.lines.map(\.label), ["Monthly", "Last 4 Weeks"])
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodMs, _) =
                mapped.lines[0] else {
            return XCTFail("Expected a monthly meter")
        }
        XCTAssertEqual(used, 5.3, accuracy: 0.0001)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertNil(resetsAt)
        XCTAssertNil(periodMs)
    }

    func testAllLimitLabelsMatchWidgetDescriptorsInDeclarationOrder() throws {
        let body = Data(#"{"limits":{"session":{"usage":0.1},"weekly":{"usage":0.2},"monthly":{"usage":0.053}},"activity":{"cost":"1.25"}}"#.utf8)
        let lines = try OllamaUsageMapper.usageLines(body)

        XCTAssertEqual(lines.map(\.label), OllamaProvider().widgetDescriptors.map(\.metricLabel))
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly", "Last 4 Weeks"])
    }

    func testZeroMonthlyUsageIsARealMeter() throws {
        let lines = try OllamaUsageMapper.usageLines(Data(#"{"limits":{"monthly":{"usage":0}}}"#.utf8))

        XCTAssertEqual(lines, [.progress(label: "Monthly", used: 0, limit: 100, format: .percent)])
    }

    func testMissingOrUnusableMonthlyUsageDoesNotInventAMeter() throws {
        for entry in ["null", "{}", #"{"usage":null}"#, #"{"usage":true}"#, #"{"usage":"invalid"}"#] {
            let body = Data("{\"limits\":{\"weekly\":{\"usage\":0.5},\"monthly\":\(entry)}}".utf8)
            XCTAssertEqual(try OllamaUsageMapper.usageLines(body), [
                .progress(label: "Weekly", used: 50, limit: 100, format: .percent)
            ], "Unexpected meter for \(entry)")
        }
    }

    func testMonthlyUsageReachesDashboardDataAndBothLocalAPIs() async throws {
        let provider = OllamaProvider()
        let registry = WidgetRegistry.from([provider])
        let snapshot = ProviderSnapshot(
            providerID: "ollama", displayName: "Ollama", plan: "Free",
            lines: try OllamaUsageMapper.usageLines(monthlyBody), refreshedAt: fetchedAt
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
        let monthly = try XCTUnwrap(registry.descriptor(id: "ollama.monthly"))
        let widget = store.data(for: monthly)
        XCTAssertTrue(widget.hasData)
        XCTAssertEqual(widget.used, 5.3, accuracy: 0.0001)
        XCTAssertEqual(widget.limit, 100)

        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["ollama"], knownIDs: ["ollama"], snapshots: ["ollama": snapshot],
            limitDescriptors: registry.limitDescriptorsByProvider, generatedAt: fetchedAt
        )
        let usageBody = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state).body)
        let usage = try XCTUnwrap(JSONSerialization.jsonObject(with: usageBody) as? [[String: Any]])
        let usageLine = try XCTUnwrap((usage.first?["lines"] as? [[String: Any]])?.first { $0["label"] as? String == "Monthly" })
        XCTAssertEqual(try XCTUnwrap(usageLine["used"] as? Double), 5.3, accuracy: 0.0001)
        XCTAssertEqual(usageLine["limit"] as? Double, 100)

        let limitsBody = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let limits = try XCTUnwrap(JSONSerialization.jsonObject(with: limitsBody) as? [String: Any])
        let account = try XCTUnwrap((limits["providers"] as? [String: Any])?["ollama"] as? [String: Any])
        let resources = try XCTUnwrap(account["resources"] as? [String: Any])
        XCTAssertEqual(Set(resources.keys), ["monthly"])
        let resource = try XCTUnwrap(resources["monthly"] as? [String: Any])
        XCTAssertEqual(resource["unit"] as? String, "percent")
        XCTAssertEqual(try XCTUnwrap(resource["used"] as? Double), 5.3, accuracy: 0.0001)
        XCTAssertEqual(resource["limit"] as? Double, 100)
        XCTAssertEqual(try XCTUnwrap(resource["utilization"] as? Double), 0.053, accuracy: 0.0001)
        XCTAssertNil(resource["resetsAt"])
    }

    func testMonthlyDefaultPlacementOnFreshInstallAndUpgradePreservesOptOuts() throws {
        let registry = WidgetRegistry.from([OllamaProvider()])
        let defaults = makeDefaults()
        let fresh = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(fresh.placed.map(\.descriptorID), [
            "ollama.session", "ollama.weekly", "ollama.monthly", "ollama.last4Weeks"
        ])
        XCTAssertFalse(fresh.expandedMetricIDs.contains("ollama.monthly"))
        XCTAssertEqual(fresh.pinnedMetricIDs, ["ollama.session", "ollama.weekly"])

        // A customized pre-monthly layout with Weekly disabled receives Monthly once and keeps pins.
        defaults.set(try JSONEncoder().encode([PlacedWidget(descriptorID: "ollama.session")]), forKey: "layout")
        defaults.set(try JSONEncoder().encode([
            "ollama.session", "ollama.weekly", "ollama.last4Weeks"
        ]), forKey: "layout.seededDefaults")
        defaults.set(["ollama.session"], forKey: "layout.menuBarPins")
        let upgraded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(upgraded.isMetricEnabled("ollama.monthly"))
        XCTAssertFalse(upgraded.isMetricEnabled("ollama.weekly"))
        XCTAssertFalse(upgraded.expandedMetricIDs.contains("ollama.monthly"))
        XCTAssertEqual(upgraded.pinnedMetricIDs, ["ollama.session"])

        upgraded.setMetricEnabled("ollama.monthly", false)
        let relaunched = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(relaunched.isMetricEnabled("ollama.monthly"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.OllamaMonthly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
