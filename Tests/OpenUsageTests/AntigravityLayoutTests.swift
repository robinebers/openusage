import XCTest
@testable import OpenUsage

/// Layout defaults and migration behavior for Antigravity's four metrics (merged quota pools +
/// weekly limits fix). Uses the real provider's registry — `MockData` carries no Antigravity
/// fixtures — with the real `DefaultLayout` seeds.
@MainActor
final class AntigravityLayoutTests: XCTestCase {

    func testFreshDefaultsSeedFourMetricsTwoPinsAndClaudePairSecondary() {
        let store = makeStore("FreshDefaults")

        // All four metrics enabled, in declaration order.
        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly"
        ])

        // The Gemini pair is pinned (2-per-provider cap), mirroring Claude/Codex Session+Weekly.
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])

        // Gemini pair above the fold; the Claude pool pair below the caret.
        let group = store.customizeGroups.first { $0.provider.id == "antigravity" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["antigravity.geminiPro", "antigravity.geminiWeekly"])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), ["antigravity.claude", "antigravity.claudeWeekly"])
    }

    func testExistingUserLayoutAutoSeedsWeeklyMetricsBelowCaretForClaudePool() {
        // A layout from before the weekly metrics shipped: Antigravity is absent from the migration
        // baseline, so `seedNewDefaultMetrics` auto-enables both new weekly metrics once. Claude
        // Weekly (a default-expanded metric) enters below the caret; metrics the user already lived
        // with stay always-shown.
        let defaults = makeDefaults("SeedWeeklies")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.claudeWeekly"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.claudeWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.geminiWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.claude"),
                       "a metric the user already lived with is never silently tucked away")
    }

    func testSavedGeminiFlashStateIsFilteredEverywhere() {
        // `antigravity.geminiFlash` no longer exists (owner-approved: its layout state drops with no
        // migration). Every load path filters unknown IDs against the registry, so stale saved state
        // self-heals.
        let defaults = makeDefaults("FlashFilter")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.geminiFlash"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)
        defaults.set(["antigravity.geminiPro", "antigravity.geminiFlash"], forKey: "layout.menuBarPins")
        saveStored(
            ["antigravity": ["antigravity.geminiFlash", "antigravity.geminiPro", "antigravity.claude"]],
            forKey: "layout.metricOrderByProvider", in: defaults
        )

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiFlash"))
        XCTAssertFalse(store.orderedSupportedMetrics(for: "antigravity").map(\.id).contains("antigravity.geminiFlash"))
        // The saved pin set is respected exactly (dead ID dropped, no weekly pin auto-added).
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro"])
    }

    func testAbsentPinsKeyAdoptsGeminiWeeklyPinOnUpgrade() {
        // Pins re-derive from current defaults whenever the pins key is absent, and init never
        // persists pins — so an existing user who never touched pins automatically gains the
        // Gemini Weekly pin (still within the 2-per-provider cap).
        let defaults = makeDefaults("PinsAbsent")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])
    }

    func testSavedPinsKeyIsRespectedExactly() {
        let defaults = makeDefaults("PinsPresent")
        saveStored([PlacedWidget(descriptorID: "antigravity.geminiPro")], forKey: "layout", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.menuBarPins")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.claude"],
                       "a user-saved pin set must not gain the new default pins")
    }

    // MARK: - Fixtures

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .antigravityOnly, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.AntigravityLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// A registry with just the live Antigravity provider, so `DefaultLayout`'s seeds filter down to
    /// its four metrics.
    @MainActor
    static var antigravityOnly: WidgetRegistry { .from([AntigravityProvider()]) }
}
