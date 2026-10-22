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

    func testNewAccountFollowsItsProvidersOnOffChoice() async {
        // An account whose login only the Keychain holds turns up a launch after the welcome screen.
        // The user skipped Codex there, so its new account stays off; Claude is on, so its joins.
        let enablement = seededStore("late-account", enabled: ["claude"], known: ["claude", "codex"])
        let codexAccount = probe("codex@ab12cd34", hasCredentials: true)
        let providers = [
            probe("claude", hasCredentials: true),
            probe("claude@ef56ab78", hasCredentials: true),
            probe("codex", hasCredentials: true),
            codexAccount
        ]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "claude@ef56ab78"])
        XCTAssertEqual(codexAccount.probeCount, 0)
    }

    func testTheEnabledIDOfARemovedCardDoesNotKeepItsFamilyOn() async {
        // Two Codex accounts were on; one was removed in Customize (its enabled id lingers), then
        // the user turned the remaining card off. A new account must stay off: no installed Codex
        // card is on, whatever the lingering id says.
        let enablement = seededStore(
            "removed-card", enabled: ["claude", "codex@removed"], known: ["claude", "codex", "codex@removed"]
        )
        let newcomer = probe("codex@brandnew", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), probe("codex", hasCredentials: true), newcomer],
            enablement: enablement
        )
        await task?.value

        XCTAssertFalse(enablement.isEnabled("codex@brandnew"))
        XCTAssertEqual(newcomer.probeCount, 0)
        XCTAssertTrue(enablement.knownIDs.contains("codex@brandnew"))

        // Control: with an installed Codex card on, the newcomer joins as before.
        let joining = seededStore("installed-on", enabled: ["claude", "codex"], known: ["claude", "codex"])
        let joiner = probe("codex@brandnew", hasCredentials: true)
        let joinTask = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), probe("codex", hasCredentials: true), joiner],
            enablement: joining
        )
        await joinTask?.value
        XCTAssertTrue(joining.isEnabled("codex@brandnew"))
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

    func testAFamilyTurnedOffDuringTheProbeKeepsItsNewCardsOff() async {
        // A live rebuild found two new Codex cards: B, whose file login is checked at once, and C, a
        // Keychain login whose check can wait on a prompt. While it waits, the user turns the
        // family's only card off. Neither newcomer may come on: the family is off now, whatever it
        // was when the probe began.
        let enablement = seededStore("family-off", enabled: ["claude", "codex@a"], known: ["claude", "codex", "codex@a"])
        let c = probe("codex@c", hasCredentials: true)
        c.holds = true

        let task = NewProviderSeeder.reconcileIfNeeded(providers: codexFamily(newcomer: c), enablement: enablement)
        for _ in 0..<1_000 where c.probeCount == 0 { await Task.yield() }
        XCTAssertEqual(c.probeCount, 1)
        enablement.setEnabled(false, for: "codex@a")
        c.release()
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude"])

        // Control: with nothing toggled during the probe, both newcomers join.
        let joining = seededStore("family-on", enabled: ["claude", "codex@a"], known: ["claude", "codex", "codex@a"])
        let joinTask = NewProviderSeeder.reconcileIfNeeded(
            providers: codexFamily(newcomer: probe("codex@c", hasCredentials: true)), enablement: joining
        )
        await joinTask?.value
        XCTAssertEqual(joining.enabledIDs, ["claude", "codex@a", "codex@b", "codex@c"])
    }

    func testACardTurnedOnAndOffDuringTheProbeStaysOff() async {
        // The user turns the new card B on, then off again, while C's check still waits. B keeps the
        // user's last word; C, which nobody touched, joins its family as usual.
        let enablement = seededStore("on-off", enabled: ["claude", "codex@a"], known: ["claude", "codex", "codex@a"])
        let c = probe("codex@c", hasCredentials: true)
        c.holds = true

        let task = NewProviderSeeder.reconcileIfNeeded(providers: codexFamily(newcomer: c), enablement: enablement)
        for _ in 0..<1_000 where c.probeCount == 0 { await Task.yield() }
        enablement.setEnabled(true, for: "codex@b")
        enablement.setEnabled(false, for: "codex@b")
        c.release()
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex@a", "codex@c"])
    }

    // MARK: - Helpers

    /// Claude and a Codex family: the known cards `codex` (off) and `codex@a` (on), the newcomer
    /// `codex@b` with a login on file, and the newcomer `c`.
    private func codexFamily(newcomer c: ProbeCountingProvider) -> [ProbeCountingProvider] {
        [
            probe("claude", hasCredentials: true), probe("codex", hasCredentials: true),
            probe("codex@a", hasCredentials: true), probe("codex@b", hasCredentials: true), c,
        ]
    }

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
        let suiteName = "OpenUsageTests.NewProviderSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class ProbeCountingProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool
    private(set) var probeCount = 0
    /// When set, the probe parks until `release()`, the way a Keychain prompt holds a check.
    var holds = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool {
        probeCount += 1
        if holds { await withCheckedContinuation { continuation = $0 } }
        return hasCredentials
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
