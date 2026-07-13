import XCTest
@testable import OpenUsage

final class LocalLimitsAPITests: XCTestCase {
    private let fetchedAt = OpenUsageISO8601.date(from: "2026-07-13T01:39:30.000Z")!
    private let generatedAt = OpenUsageISO8601.date(from: "2026-07-13T01:40:00.000Z")!

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testLimitsEnvelopeCarriesRawScalarsAndFreshnessWithoutUIPresentation() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let session = WidgetDescriptor.percent(id: "codex.session", provider: provider, title: "Session")
            .exportingLimit("session", unit: "percent")
        let credits = WidgetDescriptor.combined(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
        .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        let snapshot = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Pro 20x",
            lines: [
                .progress(
                    label: "Session", used: 42, limit: 100, format: .percent,
                    resetsAt: OpenUsageISO8601.date(from: "2026-07-13T06:00:00.000Z"),
                    periodDurationMs: 18_000_000,
                    colorHex: "#ff0000"
                ),
                .values(label: "Credits", values: [
                    MetricValue(number: 32.84, kind: .dollars),
                    MetricValue(number: 821, kind: .count, label: "credits")
                ]),
                .chart(label: "Usage Trend", points: [], note: "UI only")
            ],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["codex"],
            knownIDs: ["codex"],
            snapshots: ["codex": snapshot],
            limitDescriptors: ["codex": [session, credits]],
            generatedAt: generatedAt
        )

        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state)
        let root = try json(response.body)
        let providerJSON = try XCTUnwrap((root["providers"] as? [String: Any])?["codex"] as? [String: Any])
        let resources = try XCTUnwrap(providerJSON["resources"] as? [String: Any])
        let sessionJSON = try XCTUnwrap(resources["session"] as? [String: Any])
        let creditsJSON = try XCTUnwrap(resources["credits"] as? [String: Any])

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v1")
        XCTAssertEqual(root["generatedAt"] as? String, "2026-07-13T01:40:00.000Z")
        XCTAssertEqual(providerJSON["plan"] as? String, "Pro 20x")
        XCTAssertEqual(providerJSON["fetchedAt"] as? String, "2026-07-13T01:39:30.000Z")
        XCTAssertEqual(providerJSON["expiresAt"] as? String, "2026-07-13T01:44:30.000Z")
        XCTAssertEqual(providerJSON["stale"] as? Bool, false)
        XCTAssertEqual(sessionJSON["kind"] as? String, "consumption")
        XCTAssertEqual(sessionJSON["unit"] as? String, "percent")
        XCTAssertEqual(sessionJSON["used"] as? Double, 42)
        XCTAssertEqual(sessionJSON["limit"] as? Double, 100)
        XCTAssertEqual(sessionJSON["remaining"] as? Double, 58)
        XCTAssertEqual(try XCTUnwrap(sessionJSON["utilization"] as? Double), 0.42, accuracy: 0.000_001)
        XCTAssertEqual(sessionJSON["windowSeconds"] as? Double, 18_000)
        XCTAssertEqual(creditsJSON["kind"] as? String, "balance")
        XCTAssertEqual(creditsJSON["available"] as? Double, 821)
        XCTAssertNotNil(resources["creditValue"])
        XCTAssertNil(resources["Usage Trend"])
        XCTAssertNil(sessionJSON["color"])
        XCTAssertNil(sessionJSON["subtitle"])
        XCTAssertNil(sessionJSON["label"])

        var expiredState = state
        expiredState.generatedAt = fetchedAt.addingTimeInterval(RefreshSetting.interval)
        let expiredRoot = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: expiredState).body)
        let expiredProviders = try XCTUnwrap(expiredRoot["providers"] as? [String: Any])
        let expiredProvider = try XCTUnwrap(expiredProviders["codex"] as? [String: Any])
        XCTAssertEqual(expiredProvider["stale"] as? Bool, true)
    }

    func testUsageAndLimitsProjectTheSameRenderedSnapshot() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let session = WidgetDescriptor.percent(id: "codex.session", provider: provider, title: "Session")
            .exportingLimit("session", unit: "percent")
        let snapshot = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 73, limit: 100, format: .percent)],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["codex"],
            knownIDs: ["codex"],
            snapshots: ["codex": snapshot],
            limitDescriptors: ["codex": [session]],
            generatedAt: generatedAt
        )

        let usage = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state).body)
            ) as? [[String: Any]]
        )
        let usageLine = try XCTUnwrap((usage.first?["lines"] as? [[String: Any]])?.first)
        let limitsRoot = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let limitsProvider = try XCTUnwrap((limitsRoot["providers"] as? [String: Any])?["codex"] as? [String: Any])
        let limitsSession = try XCTUnwrap((limitsProvider["resources"] as? [String: Any])?["session"] as? [String: Any])

        XCTAssertEqual(usageLine["used"] as? Double, 73)
        XCTAssertEqual(limitsSession["used"] as? Double, 73)
    }

    func testKnownProviderRouteUsesSameEnvelopeAndPreservesMissingSnapshotStatus() throws {
        var state = LocalUsageAPI.State(
            enabledOrderedIDs: [],
            knownIDs: ["codex"],
            snapshots: [:],
            generatedAt: generatedAt
        )
        XCTAssertEqual(LocalUsageAPI.respond(method: "GET", path: "/v1/limits/codex", state: state).status, 204)
        XCTAssertEqual(LocalUsageAPI.respond(method: "GET", path: "/v1/limits/nope", state: state).status, 404)

        state.errors["codex"] = "Not logged in"
        let failed = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/codex", state: state)
        let root = try json(failed.body)
        let errors = try XCTUnwrap(root["errors"] as? [[String: Any]])
        XCTAssertEqual(failed.status, 200)
        XCTAssertTrue((root["providers"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(errors.first?["providerId"] as? String, "codex")
        XCTAssertEqual(errors.first?["message"] as? String, "Not logged in")
    }

    func testFlexibleConsumptionExportsUncappedValueWithoutInventingLimit() throws {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let extra = WidgetDescriptor.boundedDollars(
            id: "claude.extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100
        ).exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars))
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.values(label: "Extra usage spent", values: [MetricValue(number: 12.5, kind: .dollars)])],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["claude"],
            knownIDs: ["claude"],
            snapshots: ["claude": snapshot],
            limitDescriptors: ["claude": [extra]],
            generatedAt: generatedAt
        )

        let root = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let claude = try XCTUnwrap(providers["claude"] as? [String: Any])
        let resources = try XCTUnwrap(claude["resources"] as? [String: Any])
        let resource = try XCTUnwrap(resources["extraUsage"] as? [String: Any])

        XCTAssertEqual(resource["used"] as? Double, 12.5)
        XCTAssertNil(resource["limit"])
        XCTAssertNil(resource["remaining"])
        XCTAssertNil(resource["utilization"])
    }

    @MainActor
    func testEveryProviderDeclaresTheApprovedPublicResourceKeys() {
        let defaults = UserDefaults(suiteName: "LocalLimitsAPITests.\(UUID().uuidString)")!
        let registry = WidgetRegistry.from(ProviderCatalog.make(defaults: defaults))
        let actual = registry.limitDescriptorsByProvider.mapValues { descriptors in
            Set(descriptors.flatMap(\.limitResources).map(\.key))
        }
        let expected: [String: Set<String>] = [
            "claude": ["session", "weekly", "sonnet", "fable", "extraUsage"],
            "codex": ["session", "weekly", "spark", "sparkWeekly", "credits", "creditValue", "rateLimitResets"],
            "cursor": ["totalUsage", "autoUsage", "apiUsage", "onDemand", "requests", "credits"],
            "antigravity": ["geminiSession", "geminiWeekly", "nonGeminiSession", "nonGeminiWeekly"],
            "copilot": ["premiumCredits", "extraUsage", "orgCredits", "orgSpend", "chat", "completions"],
            "devin": ["daily", "weekly", "extraUsageBalance"],
            "grok": ["weekly"],
            "opencode": ["session", "weekly", "monthly"],
            "openrouter": ["credits", "balance", "keyLimit"],
            "zai": ["session", "weekly", "webSearches"]
        ]

        XCTAssertEqual(actual, expected)
    }
}
