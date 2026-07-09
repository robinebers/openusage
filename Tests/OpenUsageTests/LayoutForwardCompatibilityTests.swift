import XCTest
@testable import OpenUsage

/// Downgrade and corruption regressions stay separate from `LayoutStoreTests`: these exercise the
/// persistence boundary, including round trips through registries from two app versions.
@MainActor
final class LayoutForwardCompatibilityTests: XCTestCase {
    func testDowngradeRepairsAndEditsKnownStateWithoutDroppingFutureLayoutEntries() throws {
        let defaults = makeDefaults("DowngradeRoundTrip")
        let futureSchemaVersion = SettingsSchema.current + 1
        defaults.set(futureSchemaVersion, forKey: SettingsMigrator.schemaVersionKey)
        let keptID = UUID()
        let futurePlacedID = UUID()
        saveStored([
            PlacedWidget(id: keptID, descriptorID: "claude.session"),
            PlacedWidget(descriptorID: "claude.session"),
            PlacedWidget(id: futurePlacedID, descriptorID: "future.placed")
        ], forKey: "layout", in: defaults)
        saveStored(["cursor", "future", "cursor"], forKey: "layout.providerOrder", in: defaults)
        saveStored([
            "claude": ["claude.weekly", "claude.future", "claude.weekly"],
            "future": ["future.optional"]
        ], forKey: "layout.metricOrderByProvider", in: defaults)
        saveStored(
            ["claude.session", "future.seeded", "claude.session"],
            forKey: "layout.seededDefaults",
            in: defaults
        )
        defaults.set(["claude.session", "future.pin", "claude.session"], forKey: "layout.menuBarPins")
        defaults.set(["claude.session", "future.expanded", "claude.session"], forKey: "layout.expandedMetrics")
        defaults.set(["cursor.requests", "future.optional", "cursor.requests"], forKey: "layout.expandOnEnable")
        defaults.set(["codex", "future", "codex"], forKey: "layout.expandedProviders")

        let downgraded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )

        XCTAssertEqual(Set(downgraded.placed.map(\.descriptorID)), ["claude.session", "claude.weekly"])
        XCTAssertFalse(downgraded.providerOrder.contains("future"))
        XCTAssertFalse(downgraded.pinnedMetricIDs.contains("future.pin"))
        XCTAssertFalse(downgraded.expandedMetricIDs.contains("future.expanded"))
        XCTAssertNil(downgraded.metricOrderByProvider["future"])

        let repairedPlaced = try decode([PlacedWidget].self, key: "layout", defaults: defaults)
        XCTAssertEqual(
            repairedPlaced.map(\.descriptorID),
            ["claude.session", "future.placed", "claude.weekly"]
        )
        XCTAssertEqual(repairedPlaced[0].id, keptID)
        XCTAssertEqual(repairedPlaced[1].id, futurePlacedID)
        XCTAssertEqual(
            try decode([String].self, key: "layout.providerOrder", defaults: defaults),
            ["cursor", "future", "claude", "codex"]
        )
        let repairedMetricOrder = try decode(
            [String: [String]].self,
            key: "layout.metricOrderByProvider",
            defaults: defaults
        )
        XCTAssertEqual(
            repairedMetricOrder["claude"],
            ["claude.weekly", "claude.future", "claude.session", "claude.extra", "claude.today"]
        )
        XCTAssertEqual(repairedMetricOrder["future"], ["future.optional"])
        XCTAssertEqual(
            try decode([String].self, key: "layout.seededDefaults", defaults: defaults),
            ["claude.session", "future.seeded", "claude.weekly"]
        )
        XCTAssertEqual(defaults.stringArray(forKey: "layout.menuBarPins"), ["claude.session", "future.pin"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "layout.expandedMetrics"),
            ["claude.session", "future.expanded", "claude.weekly"]
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: "layout.expandOnEnable"),
            ["cursor.requests", "future.optional"]
        )
        XCTAssertEqual(defaults.stringArray(forKey: "layout.expandedProviders"), ["codex", "future"])

        // Exercise every identifier-bearing save after bootstrap. An older build must merge its known
        // edits into the retained projection instead of replacing settings it cannot understand.
        downgraded.resetToDefault()
        downgraded.setMetricEnabled("claude.session", false)
        downgraded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(downgraded.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertTrue(
            downgraded.reorderMetric(
                dragged: "cursor.today",
                target: "cursor.usage",
                in: "cursor"
            )
        )
        let dividerID = "cursor::future-test-expanded-divider"
        XCTAssertTrue(
            downgraded.applyMetricDividerOrder(
                ["cursor.today", "cursor.usage", "cursor.credits", dividerID, "cursor.requests"],
                dragged: "cursor.requests",
                dividerID: dividerID,
                in: "cursor"
            )
        )
        downgraded.setPinned(true, for: "cursor.usage")
        XCTAssertTrue(downgraded.setProviderExpanded(true, for: "claude"))

        let customizedPlaced = try decode([PlacedWidget].self, key: "layout", defaults: defaults)
        XCTAssertEqual(
            customizedPlaced.map(\.descriptorID),
            ["cursor.requests", "future.placed", "claude.weekly"]
        )
        XCTAssertEqual(customizedPlaced.first { $0.descriptorID == "future.placed" }?.id, futurePlacedID)
        XCTAssertEqual(
            try decode([String].self, key: "layout.providerOrder", defaults: defaults),
            ["cursor", "future", "claude", "codex"]
        )
        let customizedMetricOrder = try decode(
            [String: [String]].self,
            key: "layout.metricOrderByProvider",
            defaults: defaults
        )
        XCTAssertEqual(
            customizedMetricOrder["claude"],
            ["claude.session", "claude.future", "claude.weekly", "claude.extra", "claude.today"]
        )
        XCTAssertEqual(
            customizedMetricOrder["cursor"],
            ["cursor.today", "cursor.usage", "cursor.credits", "cursor.requests"]
        )
        XCTAssertEqual(customizedMetricOrder["future"], ["future.optional"])
        XCTAssertEqual(
            try decode([String].self, key: "layout.seededDefaults", defaults: defaults),
            ["claude.session", "future.seeded", "claude.weekly"]
        )
        XCTAssertEqual(defaults.stringArray(forKey: "layout.menuBarPins"), ["future.pin", "cursor.usage"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "layout.expandedMetrics"),
            ["future.expanded", "claude.weekly", "cursor.requests"]
        )
        XCTAssertEqual(defaults.stringArray(forKey: "layout.expandOnEnable"), ["future.optional"])
        XCTAssertEqual(defaults.stringArray(forKey: "layout.expandedProviders"), ["future", "claude"])

        let upgraded = LayoutStore(
            registry: makeFutureRegistry(),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )

        XCTAssertTrue(upgraded.isMetricEnabled("future.placed"))
        XCTAssertTrue(upgraded.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(upgraded.isMetricEnabled("claude.session"))
        XCTAssertEqual(upgraded.placed.first { $0.descriptorID == "future.placed" }?.id, futurePlacedID)
        XCTAssertEqual(upgraded.providerOrder, ["cursor", "future", "claude", "codex"])
        XCTAssertEqual(
            Array(upgraded.orderedSupportedMetrics(for: "claude").map(\.id).prefix(3)),
            ["claude.session", "claude.future", "claude.weekly"]
        )
        XCTAssertEqual(
            upgraded.orderedSupportedMetrics(for: "cursor").map(\.id),
            ["cursor.today", "cursor.usage", "cursor.credits", "cursor.requests"]
        )
        XCTAssertEqual(upgraded.orderedSupportedMetrics(for: "future").first?.id, "future.optional")
        XCTAssertTrue(upgraded.isPinned("future.pin"))
        XCTAssertTrue(upgraded.isPinned("cursor.usage"))
        XCTAssertTrue(upgraded.expandedMetricIDs.contains("future.expanded"))
        XCTAssertTrue(upgraded.expandedMetricIDs.contains("cursor.requests"))
        XCTAssertTrue(upgraded.isProviderExpanded("future"))
        XCTAssertTrue(upgraded.isProviderExpanded("claude"))
        upgraded.setMetricEnabled("future.optional", true)
        XCTAssertTrue(upgraded.expandedMetricIDs.contains("future.optional"))
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), futureSchemaVersion)
    }

    func testDuplicatePlacedUUIDAssignsFreshStableIdentityToLaterKnownWidget() throws {
        let defaults = makeDefaults("RepairPlacedUUID")
        let duplicatedID = UUID()
        saveStored([
            PlacedWidget(id: duplicatedID, descriptorID: "claude.session"),
            PlacedWidget(id: duplicatedID, descriptorID: "claude.weekly")
        ], forKey: "layout", in: defaults)
        saveStored(
            ["claude.session", "claude.weekly"],
            forKey: "layout.seededDefaults",
            in: defaults
        )

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"]
        )
        let firstID = try XCTUnwrap(store.placed.first { $0.descriptorID == "claude.session" }?.id)
        let secondID = try XCTUnwrap(store.placed.first { $0.descriptorID == "claude.weekly" }?.id)
        XCTAssertEqual(firstID, duplicatedID)
        XCTAssertNotEqual(secondID, duplicatedID)

        let repaired = try decode([PlacedWidget].self, key: "layout", defaults: defaults)
        XCTAssertEqual(repaired.map(\.id), [firstID, secondID])

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"]
        )
        XCTAssertEqual(reloaded.placed.first { $0.descriptorID == "claude.session" }?.id, firstID)
        XCTAssertEqual(reloaded.placed.first { $0.descriptorID == "claude.weekly" }?.id, secondID)
    }

    func testKnownPlacedUUIDCollisionPreservesOpaqueFutureIdentity() throws {
        let defaults = makeDefaults("RepairOpaquePlacedUUID")
        let sharedID = UUID()
        saveStored([
            PlacedWidget(id: sharedID, descriptorID: "claude.session"),
            PlacedWidget(id: sharedID, descriptorID: "future.placed")
        ], forKey: "layout", in: defaults)
        saveStored(["claude.session"], forKey: "layout.seededDefaults", in: defaults)

        let downgraded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        let knownID = try XCTUnwrap(
            downgraded.placed.first { $0.descriptorID == "claude.session" }?.id
        )
        XCTAssertNotEqual(knownID, sharedID)

        let repaired = try decode([PlacedWidget].self, key: "layout", defaults: defaults)
        XCTAssertEqual(repaired.first { $0.descriptorID == "claude.session" }?.id, knownID)
        XCTAssertEqual(repaired.first { $0.descriptorID == "future.placed" }?.id, sharedID)

        let upgraded = LayoutStore(
            registry: makeFutureRegistry(),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        XCTAssertEqual(upgraded.placed.first { $0.descriptorID == "claude.session" }?.id, knownID)
        XCTAssertEqual(upgraded.placed.first { $0.descriptorID == "future.placed" }?.id, sharedID)
        XCTAssertEqual(Set(upgraded.placed.map(\.id)).count, upgraded.placed.count)
    }

    private func makeFutureRegistry() -> WidgetRegistry {
        let future = Provider(id: "future", displayName: "Future", icon: .providerMark("future"))
        func descriptor(_ id: String, provider: Provider) -> WidgetDescriptor {
            WidgetDescriptor(
                id: id,
                providerID: provider.id,
                metricLabel: id,
                sample: WidgetData(
                    title: id,
                    icon: provider.icon,
                    kind: .percent,
                    used: 0,
                    limit: 100
                )
            )
        }

        return WidgetRegistry(
            providers: MockData.providers + [future],
            descriptors: MockData.descriptors + [
                descriptor("claude.future", provider: MockData.claude),
                descriptor("future.placed", provider: future),
                descriptor("future.pin", provider: future),
                descriptor("future.expanded", provider: future),
                descriptor("future.optional", provider: future),
                descriptor("future.seeded", provider: future)
            ]
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.LayoutForwardCompatibility.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(defaults.data(forKey: key)))
    }
}
