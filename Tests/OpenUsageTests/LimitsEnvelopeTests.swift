import XCTest
@testable import OpenUsage

/// The `openusage` command's limits JSON: the documented envelope, raw scalars with explicit units,
/// freshness, and which rows stay out of it.
final class LimitsEnvelopeTests: XCTestCase {
    private let fetchedAt = OpenUsageISO8601.date(from: "2026-07-13T01:39:30.000Z")!
    private let generatedAt = OpenUsageISO8601.date(from: "2026-07-13T01:40:00.000Z")!

    /// The example in docs/cli.md.
    private static let documentedExample = """
    {
      "schema": "openusage.limits.v1",
      "generatedAt": "2026-07-13T01:40:00.000Z",
      "providers": {
        "codex": {
          "displayName": "Codex",
          "plan": "Pro 200",
          "fetchedAt": "2026-07-13T01:39:30.000Z",
          "expiresAt": "2026-07-13T01:44:30.000Z",
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
      },
      "errors": []
    }
    """

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func input(snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor]) -> LimitsEnvelope.Input {
        LimitsEnvelope.Input(
            providerIDs: [snapshot.providerID],
            snapshots: [snapshot.providerID: snapshot],
            limitDescriptors: [snapshot.providerID: descriptors],
            generatedAt: generatedAt
        )
    }

    private func limitResource(
        _ key: String,
        snapshot: ProviderSnapshot,
        descriptors: [WidgetDescriptor]
    ) throws -> [String: Any] {
        let root = try json(LimitsEnvelope.encode(input(snapshot: snapshot, descriptors: descriptors)))
        let provider = try XCTUnwrap((root["providers"] as? [String: Any])?[snapshot.providerID] as? [String: Any])
        return try XCTUnwrap((provider["resources"] as? [String: Any])?[key] as? [String: Any])
    }

    @MainActor
    func testEnvelopeMatchesTheDocumentedExample() throws {
        let account = Account(kind: .codex, label: "Codex")
        let snapshot = ProviderSnapshot(
            providerID: account.cardID,
            displayName: "Codex",
            plan: "Pro 200",
            lines: [
                .progress(label: "Session", used: 42, limit: 100, format: .percent,
                          resetsAt: OpenUsageISO8601.date(from: "2026-07-13T06:00:00.000Z"),
                          periodDurationMs: 18_000_000),
                .values(label: "Credits", values: [MetricValue(number: 821, kind: .count, label: "credits")])
            ],
            refreshedAt: fetchedAt
        )
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account)
        let actual = try json(LimitsEnvelope.encode(input(snapshot: snapshot, descriptors: descriptors)))
        let expected = try json(Data(
            Self.documentedExample.replacingOccurrences(of: "\"codex\": {", with: "\"\(account.cardID)\": {").utf8
        ))

        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
    }

    func testEnvelopeCarriesRawScalarsAndFreshnessWithoutUIPresentation() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: "codex")
        let session = WidgetDescriptor.percent(id: "codex.session", provider: provider, title: "Session")
            .exportingLimit("session", unit: "percent")
        let credits = WidgetDescriptor.values(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
        .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        let snapshot = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Pro 200",
            lines: [
                .progress(
                    label: "Session", used: 42, limit: 100, format: .percent,
                    resetsAt: OpenUsageISO8601.date(from: "2026-07-13T06:00:00.000Z"),
                    periodDurationMs: 18_000_000
                ),
                .values(label: "Credits", values: [
                    MetricValue(number: 32.84, kind: .dollars),
                    MetricValue(number: 821, kind: .count, label: "credits")
                ]),
                .badge(label: "Pay as you go", text: "2500 cap")
            ],
            refreshedAt: fetchedAt
        )
        let input = input(snapshot: snapshot, descriptors: [session, credits])

        let root = try json(LimitsEnvelope.encode(input))
        let providerJSON = try XCTUnwrap((root["providers"] as? [String: Any])?["codex"] as? [String: Any])
        let resources = try XCTUnwrap(providerJSON["resources"] as? [String: Any])
        let sessionJSON = try XCTUnwrap(resources["session"] as? [String: Any])
        let creditsJSON = try XCTUnwrap(resources["credits"] as? [String: Any])
        let creditValueJSON = try XCTUnwrap(resources["creditValue"] as? [String: Any])

        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v1")
        XCTAssertEqual(root["generatedAt"] as? String, "2026-07-13T01:40:00.000Z")
        XCTAssertEqual(providerJSON["plan"] as? String, "Pro 200")
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
        XCTAssertEqual(creditValueJSON["available"] as? Double, 32.84)
        XCTAssertEqual(creditValueJSON["unit"] as? String, "usd")
        XCTAssertEqual(Set(resources.keys), ["session", "credits", "creditValue"])
        XCTAssertNil(sessionJSON["label"])

        var expired = input
        expired.generatedAt = fetchedAt.addingTimeInterval(RefreshSetting.interval)
        let expiredRoot = try json(LimitsEnvelope.encode(expired))
        let expiredProvider = try XCTUnwrap((expiredRoot["providers"] as? [String: Any])?["codex"] as? [String: Any])
        XCTAssertEqual(expiredProvider["stale"] as? Bool, true)
    }

    func testCardWithoutSnapshotHasNoEntryAndFailedRefreshIsListedUnderErrors() throws {
        var input = LimitsEnvelope.Input(providerIDs: ["codex@ab12cd34"], snapshots: [:], generatedAt: generatedAt)
        let pending = try json(LimitsEnvelope.encode(input))
        XCTAssertTrue((pending["providers"] as? [String: Any])?.isEmpty == true)
        XCTAssertTrue((pending["errors"] as? [Any])?.isEmpty == true)

        input.errors["codex@ab12cd34"] = "Not logged in"
        let failed = try json(LimitsEnvelope.encode(input))
        let errors = try XCTUnwrap(failed["errors"] as? [[String: Any]])
        XCTAssertTrue((failed["providers"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?["providerId"] as? String, "codex@ab12cd34")
        XCTAssertEqual(errors.first?["message"] as? String, "Not logged in")
    }

    func testProvidersPrintInTheRequestedOrderAndOnlyThoseRequested() throws {
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: "zai")
        let weekly = WidgetDescriptor.percent(id: "zai.weekly", provider: provider, title: "Weekly")
            .exportingLimit("weekly", unit: "percent")
        func snapshot(_ id: String) -> ProviderSnapshot {
            ProviderSnapshot(providerID: id, displayName: "Z.ai",
                             lines: [.progress(label: "Weekly", used: 1, limit: 100, format: .percent)],
                             refreshedAt: fetchedAt)
        }
        let input = LimitsEnvelope.Input(
            providerIDs: ["zai@2", "zai@1"],
            snapshots: ["zai@1": snapshot("zai@1"), "zai@2": snapshot("zai@2"), "zai@3": snapshot("zai@3")],
            limitDescriptors: ["zai@1": [weekly], "zai@2": [weekly], "zai@3": [weekly]],
            generatedAt: generatedAt
        )

        let root = try json(LimitsEnvelope.encode(input))
        XCTAssertEqual(Set((root["providers"] as? [String: Any])?.keys.map { $0 } ?? []), ["zai@1", "zai@2"])
    }

    func testFlexibleConsumptionExportsUncappedValueWithoutInventingLimit() throws {
        let provider = Provider(id: "claude", displayName: "Claude", icon: "claude")
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
        let resource = try limitResource("extraUsage", snapshot: snapshot, descriptors: [extra])

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

        let count = try limitResource("premiumCredits", snapshot: personal, descriptors: [credits])
        XCTAssertEqual(count["used"] as? Double, 2111)
        XCTAssertEqual(count["unit"] as? String, "credits")
        XCTAssertNil(count["limit"])

        let percent = try limitResource("premiumCredits", snapshot: paid, descriptors: [credits])
        XCTAssertEqual(percent["used"] as? Double, 59)
        XCTAssertEqual(percent["unit"] as? String, "percent")
        XCTAssertEqual(percent["limit"] as? Double, 100)
    }

    func testProgressResourceUnitFollowsRuntimeMetricFormat() throws {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: "cursor")
        let total = WidgetDescriptor.percent(
            id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage"
        ).exportingLimit("totalUsage", unit: "percent")
        let snapshot = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 37, limit: 750, format: .count(suffix: "requests"))],
            refreshedAt: fetchedAt
        )
        let resource = try limitResource("totalUsage", snapshot: snapshot, descriptors: [total])

        XCTAssertEqual(resource["unit"] as? String, "requests")
        XCTAssertEqual(resource["used"] as? Double, 37)
        XCTAssertEqual(resource["limit"] as? Double, 750)
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
        let resource = try limitResource("rateLimitResets", snapshot: snapshot, descriptors: descriptors)

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
        let argon = try limitResource("argonWeekly", snapshot: snapshot, descriptors: descriptors)
        let gemini = try limitResource("geminiWeekly", snapshot: snapshot, descriptors: descriptors)

        XCTAssertEqual(argon["unit"] as? String, "percent")
        XCTAssertEqual(argon["used"] as? Double, 75)
        XCTAssertEqual(argon["remaining"] as? Double, 25)
        XCTAssertEqual(argon["windowSeconds"] as? Double, 604_800)
        XCTAssertEqual(argon["resetsAt"] as? String, OpenUsageISO8601.string(from: reset))
        XCTAssertEqual(gemini["used"] as? Double, 10)

        snapshot.lines.removeAll { $0.label == AntigravityMetric.argonWeeklyLabel }
        let root = try json(LimitsEnvelope.encode(input(snapshot: snapshot, descriptors: descriptors)))
        let provider = try XCTUnwrap((root["providers"] as? [String: Any])?[account.cardID] as? [String: Any])
        XCTAssertEqual(Set((provider["resources"] as? [String: Any])?.keys.map { $0 } ?? []), ["geminiWeekly"])
    }

    @MainActor
    func testEveryProviderKindDeclaresTheDocumentedResourceKeys() {
        let actual = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { kind in
            let descriptors = AccountProviderRuntime.widgetDescriptors(for: Account(kind: kind, label: kind.displayName))
            return (kind.rawValue, Set(descriptors.flatMap(\.limitResources).map(\.key)))
        })
        let expected: [String: Set<String>] = [
            "claude": ["session", "weekly", "sonnet", "fable", "extraUsage", "rateLimitResets"],
            "codex": ["session", "weekly", "spark", "sparkWeekly", "credits", "creditValue", "rateLimitResets"],
            "cursor": ["totalUsage", "grokBot", "autoUsage", "apiUsage", "onDemand", "requests", "credits"],
            "antigravity": ["geminiSession", "geminiWeekly", "argonWeekly", "nonGeminiSession", "nonGeminiWeekly"],
            "copilot": ["premiumCredits", "extraUsage", "chat", "completions"],
            "grok": ["weekly"],
            "ollama": ["session", "weekly", "monthly", "purchasedCredits"],
            "opencode": ["session", "weekly", "monthly"],
            "openrouter": ["balance"],
            "zai": ["session", "weekly", "webSearches"]
        ]

        XCTAssertEqual(actual, expected)
    }
}
