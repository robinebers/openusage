import XCTest
@testable import OpenUsage

final class LimitsEnvelopeTests: XCTestCase {
    private let fetchedAt = OpenUsageISO8601.date(from: "2026-07-13T01:39:30.000Z")!
    private let generatedAt = OpenUsageISO8601.date(from: "2026-07-13T01:40:00.000Z")!

    private static let documentedExample = """
    {
      "schema": "openusage.limits.v2",
      "generatedAt": "2026-07-13T01:40:00.000Z",
      "providers": {
        "codex": {
          "displayName": "ChatGPT · Work",
          "plan": "Pro 200",
          "fetchedAt": "2026-07-13T01:39:30.000Z",
          "expiresAt": "2026-07-13T01:49:30.000Z",
          "stale": false,
          "resources": {
            "session": {
              "kind": "consumption",
              "unit": "percent",
              "used": 42,
              "limit": 100,
              "remaining": 58,
              "utilization": 0.42,
              "resetsAt": "2026-07-13T06:00:00.000Z",
              "windowSeconds": 18000
            },
            "credits": {
              "kind": "balance",
              "unit": "credits",
              "available": 821
            }
          }
        }
      }
    }
    """

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func input(_ provider: Provider, snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor]) -> LimitsEnvelope.Input {
        LimitsEnvelope.Input(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            snapshots: [provider.id: snapshot],
            generatedAt: generatedAt
        )
    }

    private func limitResource(
        _ key: String,
        of provider: Provider,
        snapshot: ProviderSnapshot,
        descriptors: [WidgetDescriptor]
    ) throws -> [String: Any] {
        let root = try json(LimitsEnvelope.encode(input(provider, snapshot: snapshot, descriptors: descriptors)))
        let entry = try XCTUnwrap((root["providers"] as? [String: Any])?[provider.id] as? [String: Any])
        return try XCTUnwrap((entry["resources"] as? [String: Any])?[key] as? [String: Any])
    }

    @MainActor
    func testEnvelopeMatchesTheDocumentedExample() throws {
        let account = Account(kind: .codex, label: "Work")
        let snapshot = ProviderSnapshot(
            providerID: account.cardID,
            displayName: "ChatGPT",
            plan: "Pro 200",
            lines: [
                .progress(label: "Session", used: 42, limit: 100, format: .percent,
                          resetsAt: OpenUsageISO8601.date(from: "2026-07-13T06:00:00.000Z"),
                          periodDurationMs: 18_000_000),
                .values(label: "Credits", values: CodexUsageMapper.creditValues(remaining: 821.6)),
                .badge(label: "Pay as you go", text: "2500 cap")
            ],
            refreshedAt: fetchedAt
        )
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account)
        let provider = AccountProviderRuntime.provider(for: account)
        var request = input(provider, snapshot: snapshot, descriptors: descriptors)
        let actual = try json(LimitsEnvelope.encode(request))
        let expected = try json(Data(
            Self.documentedExample.replacingOccurrences(of: "\"codex\": {", with: "\"\(account.cardID)\": {").utf8
        ))

        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)

        request.generatedAt = fetchedAt.addingTimeInterval(RefreshSetting.stalenessThreshold)
        let expired = try json(LimitsEnvelope.encode(request))
        let entries = try XCTUnwrap(expired["providers"] as? [String: [String: Any]])
        XCTAssertEqual(entries[account.cardID]?["stale"] as? Bool, true)
    }

    func testCardWithoutSnapshotHasNoEntryAndTheEnvelopeHasOnlyFilledKeys() throws {
        let input = LimitsEnvelope.Input(
            registry: WidgetRegistry(providers: [Provider(id: "codex@ab12cd34", kind: .codex)], descriptors: []),
            snapshots: [:],
            generatedAt: generatedAt
        )
        let pending = try json(LimitsEnvelope.encode(input))
        XCTAssertTrue((pending["providers"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(Set(pending.keys), ["schema", "generatedAt", "providers"])
    }

    func testProvidersPrintInTheRequestedOrderAndOnlyThoseRequested() throws {
        let providers = ["zai@2", "zai@1"].map { Provider(id: $0, kind: .zai) }
        let weekly = providers.map {
            WidgetDescriptor.percent(key: "weekly", provider: $0, title: "Weekly").exportingLimit("weekly", unit: "percent")
        }
        func snapshot(_ id: String) -> ProviderSnapshot {
            ProviderSnapshot(providerID: id, displayName: "Z.ai",
                             lines: [.progress(label: "Weekly", used: 1, limit: 100, format: .percent)],
                             refreshedAt: fetchedAt)
        }
        let input = LimitsEnvelope.Input(
            registry: WidgetRegistry(providers: providers, descriptors: weekly),
            snapshots: ["zai@1": snapshot("zai@1"), "zai@2": snapshot("zai@2"), "zai@3": snapshot("zai@3")],
            generatedAt: generatedAt
        )

        let root = try json(LimitsEnvelope.encode(input))
        XCTAssertEqual(Set((root["providers"] as? [String: Any])?.keys.map { $0 } ?? []), ["zai@1", "zai@2"])
    }

    func testFlexibleConsumptionExportsUncappedValueWithoutInventingLimit() throws {
        let provider = Provider(id: "claude", kind: .claude)
        let extra = WidgetDescriptor.boundedDollars(
            key: "extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100
        ).exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars))
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.values(label: "Extra usage spent", values: [MetricValue(number: 12.5, kind: .dollars)])],
            refreshedAt: fetchedAt
        )
        let resource = try limitResource("extraUsage", of: provider, snapshot: snapshot, descriptors: [extra])

        XCTAssertEqual(resource["used"] as? Double, 12.5)
        XCTAssertEqual(resource["unit"] as? String, "usd")
        XCTAssertNil(resource["limit"])
        XCTAssertNil(resource["remaining"])
        XCTAssertNil(resource["utilization"])
    }

    @MainActor
    func testCopilotPremiumCreditsExportsPersonalCountAndPaidPercent() throws {
        let account = Account(kind: .copilot, label: "Copilot")
        let credits = AccountProviderRuntime.widgetDescriptors(for: account).first { $0.id == "\(account.cardID).premium" }!
        let personal = ProviderSnapshot(
            providerID: account.cardID,
            displayName: "Copilot",
            plan: "Business",
            lines: [.values(label: "Credits", values: [MetricValue(number: 2111, kind: .count)])],
            refreshedAt: fetchedAt
        )
        let paid = ProviderSnapshot(
            providerID: account.cardID,
            displayName: "Copilot",
            plan: "Pro",
            lines: [.progress(label: "Credits", used: 59, limit: 100, format: .percent)],
            refreshedAt: fetchedAt
        )

        let provider = AccountProviderRuntime.provider(for: account)
        let count = try limitResource("premiumCredits", of: provider, snapshot: personal, descriptors: [credits])
        XCTAssertEqual(count["used"] as? Double, 2111)
        XCTAssertEqual(count["unit"] as? String, "credits")
        XCTAssertNil(count["limit"])

        let percent = try limitResource("premiumCredits", of: provider, snapshot: paid, descriptors: [credits])
        XCTAssertEqual(percent["used"] as? Double, 59)
        XCTAssertEqual(percent["unit"] as? String, "percent")
        XCTAssertEqual(percent["limit"] as? Double, 100)
    }

    func testProgressResourceUnitFollowsRuntimeMetricFormat() throws {
        let provider = Provider(id: "cursor", kind: .cursor)
        let total = WidgetDescriptor.percent(
            key: "usage", provider: provider, title: "Total Usage", metricLabel: "Total usage"
        ).exportingLimit("totalUsage", unit: "percent")
        let snapshot = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 37, limit: 750, format: .count(suffix: "requests"))],
            refreshedAt: fetchedAt
        )
        let resource = try limitResource("totalUsage", of: provider, snapshot: snapshot, descriptors: [total])

        XCTAssertEqual(resource["unit"] as? String, "requests")
        XCTAssertEqual(resource["used"] as? Double, 37)
        XCTAssertEqual(resource["limit"] as? Double, 750)
    }

    @MainActor
    func testAReportedZeroCodexBalanceIsExported() throws {
        let account = Account(kind: .codex, label: "ChatGPT")
        let provider = AccountProviderRuntime.provider(for: account)
        let usage = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"credits":{"balance":"0"}}"#.utf8))
        )
        let resource = try limitResource(
            "credits", of: provider, snapshot: ProviderSnapshot(provider: provider, plan: usage.plan, lines: usage.lines),
            descriptors: AccountProviderRuntime.widgetDescriptors(for: account)
        )
        XCTAssertEqual(resource["available"] as? Double, 0)
    }

    @MainActor
    func testResetExpiriesPrintSortedAsISO8601() throws {
        let account = Account(kind: .claude, label: "Claude")
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account)
        let later = OpenUsageISO8601.date(from: "2026-07-20T01:39:30.000Z")!
        let sooner = OpenUsageISO8601.date(from: "2026-07-14T01:39:30.000Z")!
        let snapshot = ProviderSnapshot(
            providerID: account.cardID,
            displayName: "Claude",
            lines: [.values(label: "Rate Limit Resets",
                            values: [MetricValue(number: 2, kind: .count, label: "available")],
                            expiriesAt: [later, sooner])],
            refreshedAt: fetchedAt
        )
        let resource = try limitResource(
            "rateLimitResets", of: AccountProviderRuntime.provider(for: account), snapshot: snapshot, descriptors: descriptors
        )

        XCTAssertEqual(resource["kind"] as? String, "balance")
        XCTAssertEqual(resource["unit"] as? String, "resets")
        XCTAssertEqual(resource["available"] as? Double, 2)
        XCTAssertEqual(resource["expiresAt"] as? [String], ["2026-07-14T01:39:30.000Z", "2026-07-20T01:39:30.000Z"])
    }

    @MainActor
    func testAntigravityArgonWeeklyExportsSeparatelyAndIsOmittedWhenAbsent() throws {
        let account = Account(kind: .antigravity, label: "Antigravity")
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account)
        let reset = OpenUsageISO8601.date(from: "2026-07-20T01:39:30.000Z")!
        var snapshot = ProviderSnapshot(
            providerID: account.cardID,
            displayName: "Antigravity",
            plan: "Pro",
            lines: [
                .progress(label: AntigravityMetric.weeklyLabel, used: 10, limit: 100, format: .percent,
                          periodDurationMs: MetricPeriod.weekMs),
                .progress(label: AntigravityMetric.argonWeeklyLabel, used: 75, limit: 100, format: .percent,
                          resetsAt: reset, periodDurationMs: MetricPeriod.weekMs)
            ],
            refreshedAt: fetchedAt
        )
        let provider = AccountProviderRuntime.provider(for: account)
        let argon = try limitResource("argonWeekly", of: provider, snapshot: snapshot, descriptors: descriptors)
        let gemini = try limitResource("geminiWeekly", of: provider, snapshot: snapshot, descriptors: descriptors)

        XCTAssertEqual(argon["unit"] as? String, "percent")
        XCTAssertEqual(argon["used"] as? Double, 75)
        XCTAssertEqual(argon["remaining"] as? Double, 25)
        XCTAssertEqual(argon["windowSeconds"] as? Double, 604_800)
        XCTAssertEqual(argon["resetsAt"] as? String, OpenUsageISO8601.string(from: reset))
        XCTAssertEqual(gemini["used"] as? Double, 10)

        snapshot.lines.removeAll { $0.label == AntigravityMetric.argonWeeklyLabel }
        let root = try json(LimitsEnvelope.encode(input(provider, snapshot: snapshot, descriptors: descriptors)))
        let entry = try XCTUnwrap((root["providers"] as? [String: Any])?[account.cardID] as? [String: Any])
        XCTAssertEqual(Set((entry["resources"] as? [String: Any])?.keys.map { $0 } ?? []), ["geminiWeekly"])
    }

    @MainActor
    func testEveryProviderKindDeclaresTheDocumentedResourceKeys() {
        let actual = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { kind in
            let descriptors = AccountProviderRuntime.widgetDescriptors(for: Account(kind: kind, label: kind.displayName))
            return (kind.rawValue, Set(descriptors.flatMap(\.limitResources).map(\.key)))
        })
        let expected: [String: Set<String>] = [
            "claude": ["session", "weekly", "sonnet", "fable", "extraUsage", "rateLimitResets"],
            "codex": ["session", "weekly", "spark", "sparkWeekly", "credits", "rateLimitResets"],
            "cursor": ["totalUsage", "grokBot", "autoUsage", "apiUsage", "onDemand", "requests", "credits"],
            "antigravity": ["geminiSession", "geminiWeekly", "argonWeekly", "nonGeminiSession", "nonGeminiWeekly"],
            "copilot": ["premiumCredits", "extraUsage", "chat", "completions"],
            "devin": ["daily", "weekly", "extraUsageBalance"],
            "grok": ["weekly"],
            "ollama": ["session", "weekly", "monthly", "purchasedCredits"],
            "opencode": ["session", "weekly", "monthly"],
            "openrouter": ["balance", "keyLimit"],
            "zai": ["session", "weekly", "webSearches"]
        ]

        XCTAssertEqual(actual, expected)
        let organization = AccountProviderRuntime.widgetDescriptors(for: Account(kind: .copilot, label: "acme", organization: "acme"))
        XCTAssertEqual(Set(organization.flatMap(\.limitResources).map(\.key)), ["orgCredits", "orgSpend"])
    }
}
