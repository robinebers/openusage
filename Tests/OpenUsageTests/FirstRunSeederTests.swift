import XCTest
@testable import OpenUsage

/// Covers the fresh-install seeding flow: only fresh installs are seeded (existing installs keep the
/// legacy all-on default untouched), the fallback set lands synchronously, the detected set replaces it
/// once the local credential probe finishes, and a user's toggle during the probe wins over detection.
@MainActor
final class FirstRunSeederTests: XCTestCase {
    func testFreshInstallSeedsFallbackSynchronouslyThenDetectedSet() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("detect"))
        let onboarding = OnboardingStore(defaults: makeDefaults("detect-onboarding"))
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )

        // Before the probe finishes: the fallback set, synchronously — never a flash of all providers.
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor"])
        XCTAssertTrue(onboarding.isCustomizeHintPending)
        // Every provider shipping today is baselined as "seen", so `NewProviderSeeder` only ever
        // probes providers added in a later release.
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "cursor", "grok"])

        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testNothingDetectedKeepsFallback() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("none"))
        let onboarding = OnboardingStore(defaults: makeDefaults("none-onboarding"))
        let providers = ["claude", "codex", "cursor", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor"])
    }

    func testExistingInstallIsNeverSeeded() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("existing"))
        let onboarding = OnboardingStore(defaults: makeDefaults("existing-onboarding"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs, "an existing install keeps legacy all-on semantics")
        XCTAssertTrue(enablement.isEnabled("grok"))
        XCTAssertFalse(onboarding.isCustomizeHintPending, "existing installs never see the hint card")
    }

    func testAlreadySeededStoreIsNotReseeded() {
        // An unbundled `swift run` reports fresh on every launch; the enabled-list guard keeps a
        // second pass from overwriting the user's choices.
        let defaults = makeDefaults("idempotent")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["grok"])
        let onboarding = OnboardingStore(defaults: makeDefaults("idempotent-onboarding"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("toggle-wins"))
        let onboarding = OnboardingStore(defaults: makeDefaults("toggle-wins-onboarding"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("cursor", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        // The user flips a toggle while the probe is still running: their arrangement must survive.
        enablement.setEnabled(false, for: "codex")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "cursor"])
    }

    // MARK: - Reset All reseed

    func testReseedOverwritesCurrentChoicesWithDetectedSet() async {
        // The user had a hand-tuned set on; Reset All must re-detect and switch to exactly what's
        // installed — even turning off a provider they had enabled that has no local credentials.
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed"))
        enablement.seedEnabledProviders(["codex", "grok"])
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)

        // Snaps to the fallback synchronously so the dashboard reflects the reset immediately.
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor"])

        await task.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testReseedKeepsFallbackWhenNothingDetected() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-none"))
        enablement.seedEnabledProviders(["grok"])
        let providers = ["claude", "codex", "cursor", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor"])
    }

    func testReseedUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-toggle"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("cursor", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        // The user flips a toggle while the probe is still running: their arrangement must survive.
        enablement.setEnabled(false, for: "codex")
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "cursor"])
    }

    // MARK: - Concurrent detection

    func testDetectLocalProvidersProbesConcurrently() async {
        // A single probe can block on a `security`/`sqlite3` subprocess for seconds, so probing
        // sequentially made first-launch detection take the sum of all providers' waits. Each gated
        // stub suspends until every probe has *started* (and reports a credential only then), so a
        // sequential regression — where the first probe would finish before the second begins — fails
        // the assertion instead of detecting anything.
        let ids = ["claude", "codex", "cursor", "grok"]
        let gate = ProbeGate(expected: ids.count)
        let providers = ids.map { GatedCredentialProvider(id: $0, gate: gate) }

        let detected = await FirstRunSeeder.detectLocalProviders(providers)

        XCTAssertEqual(detected, Set(ids), "all probes must be in flight at once, not one after another")
    }

    // MARK: - OnboardingStore persistence

    func testCustomizeHintFlagPersistsAcrossInstances() {
        let defaults = makeDefaults("hint-persist")
        let store = OnboardingStore(defaults: defaults)
        XCTAssertFalse(store.isCustomizeHintPending)

        store.markCustomizeHintPending()
        XCTAssertTrue(OnboardingStore(defaults: defaults).isCustomizeHintPending)

        store.dismissCustomizeHint()
        XCTAssertFalse(store.isCustomizeHintPending)
        XCTAssertFalse(OnboardingStore(defaults: defaults).isCustomizeHintPending)
    }

    // MARK: - Helpers

    private func stub(_ id: String, hasCredentials: Bool) -> CredentialStubProvider {
        CredentialStubProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.FirstRunSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class CredentialStubProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { hasCredentials }
}

/// A provider whose credential probe suspends on a shared `ProbeGate` until all expected probes have
/// started — "credentials found" therefore means "my probe overlapped every other probe".
@MainActor
private final class GatedCredentialProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let gate: ProbeGate

    init(id: String, gate: ProbeGate) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.gate = gate
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { await gate.arrive() }
}

/// Suspends each arriver until `expected` arrivals are in flight, then resumes them all with `true`.
/// A safety valve resumes stragglers with `false` after a few seconds, so a sequential-probing
/// regression fails the test's assertion instead of hanging the suite.
@MainActor
private final class ProbeGate {
    private let expected: Int
    private var arrived = 0
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() async -> Bool {
        arrived += 1
        if arrived == expected {
            for waiter in waiters.values {
                waiter.resume(returning: true)
            }
            waiters = [:]
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let waiter = self?.waiters.removeValue(forKey: id) else { return }
                waiter.resume(returning: false)
            }
        }
    }
}
