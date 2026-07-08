import XCTest
@testable import OpenUsage

/// Covers the new-provider detection pass that runs on every launch: only providers the install has
/// never seen are credential-probed, a probe hit turns the provider on, a miss leaves it off forever
/// (one shot), and providers the user already decided about are never touched.
@MainActor
final class NewProviderSeederTests: XCTestCase {
    func testNewProviderWithCredentialsIsEnabled() async {
        let enablement = seededStore("detect", enabled: ["claude"], known: ["claude", "codex"])
        let providers = [
            probe("claude", hasCredentials: true),
            probe("codex", hasCredentials: true),
            probe("windsurf", hasCredentials: true)
        ]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "windsurf"])
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "windsurf"])
    }

    func testNewProviderWithoutCredentialsStaysOffAndIsNeverReprobed() async {
        let enablement = seededStore("miss", enabled: ["claude"], known: ["claude"])
        let newcomer = probe("windsurf", hasCredentials: false)

        let firstRun = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), newcomer], enablement: enablement
        )
        await firstRun?.value

        XCTAssertFalse(enablement.isEnabled("windsurf"))
        XCTAssertEqual(newcomer.probeCount, 1)

        // Next launch: windsurf is known now — no task, no second probe. Enabling it is the user's call.
        let secondRun = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), newcomer], enablement: enablement
        )
        XCTAssertNil(secondRun)
        XCTAssertEqual(newcomer.probeCount, 1)
    }

    func testKnownButDisabledProviderIsNeverProbedOrReenabled() async {
        // The user turned grok off at some point; it must never come back on its own — even though a
        // credential probe would hit.
        let enablement = seededStore("user-off", enabled: ["claude"], known: ["claude", "grok"])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertNil(task, "nothing new to detect")
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testLegacyModeStoreIsUntouched() {
        // Legacy disabled-list installs get new providers on by default already; the seeder must not
        // switch their mode or write anything.
        let enablement = ProviderEnablementStore(defaults: makeDefaults("legacy"))

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("windsurf", hasCredentials: true)], enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs)
        XCTAssertTrue(enablement.knownIDs.isEmpty)
    }

    func testEmptyKnownSetIsBaselinedWithoutProbing() {
        // An enabled-list store with no known set (an unbundled `swift run` seeded before this
        // shipped): "new" can't be told apart from "user turned it off", so baseline and do nothing.
        let enablement = seededStore("baseline", enabled: ["claude"], known: [])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.knownIDs, ["claude", "grok"])
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = seededStore("toggle-wins", enabled: ["claude"], known: ["claude"])
        var enableCallbacks: [String] = []
        enablement.onProviderEnabled = { enableCallbacks.append($0) }
        let providers = [probe("claude", hasCredentials: true), probe("windsurf", hasCredentials: true)]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        // The user turns the newcomer on themselves while the probe is still running: the seeder must
        // leave their toggle alone instead of re-setting it.
        enablement.setEnabled(true, for: "windsurf")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "windsurf"])
        XCTAssertEqual(enableCallbacks, ["windsurf"], "the seeder must not fire a second enable")
    }

    // MARK: - Helpers

    private func seededStore(_ name: String, enabled: Set<String>, known: Set<String>) -> ProviderEnablementStore {
        let store = ProviderEnablementStore(defaults: makeDefaults(name))
        store.seedEnabledProviders(enabled)
        store.registerKnownProviders(known)
        return store
    }

    private func probe(_ id: String, hasCredentials: Bool) -> ProbeCountingProvider {
        ProbeCountingProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        makeScratchDefaults(suiteName: "OpenUsageTests.NewProviderSeeder.\(name).\(UUID().uuidString)")
    }
}

@MainActor
private final class ProbeCountingProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool
    private(set) var probeCount = 0

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool {
        probeCount += 1
        return hasCredentials
    }
}
