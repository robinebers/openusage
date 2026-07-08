import XCTest
@testable import OpenUsage

/// Covers the persistence contract of `ProviderEnablementStore`: only *disabled* IDs are stored, so an
/// empty suite means everything is on and the choice survives relaunch.
@MainActor
final class ProviderEnablementStoreTests: XCTestCase {
    func testEmptySuiteEnablesEverything() {
        let store = ProviderEnablementStore(defaults: makeDefaults("empty"))

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
    }

    func testDisablingPersistsAcrossInstances() {
        let defaults = makeDefaults("persist")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "codex")

        XCTAssertFalse(store.isEnabled("codex"))
        XCTAssertTrue(store.isEnabled("claude"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.disabledIDs, ["codex"])
        XCTAssertFalse(reloaded.isEnabled("codex"))
        XCTAssertTrue(reloaded.isEnabled("claude"))
    }

    func testReEnablingClearsDisabledStateAndPersists() {
        let defaults = makeDefaults("re-enable")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "grok")
        store.setEnabled(true, for: "grok")

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("grok"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(reloaded.disabledIDs.isEmpty)
        XCTAssertTrue(reloaded.isEnabled("grok"))
    }

    // MARK: - Early-refresh signal

    func testRealChangePostsDidChangeNotification() {
        let store = ProviderEnablementStore(defaults: makeDefaults("notify-change"))
        let posted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)

        store.setEnabled(false, for: "codex")   // enabled -> disabled: a real change

        wait(for: [posted], timeout: 1)
    }

    func testNoOpToggleDoesNotPostDidChangeNotification() {
        // The refresh loop wakes on this notification; a redundant toggle must not wake it (and re-probe).
        let store = ProviderEnablementStore(defaults: makeDefaults("notify-noop"))
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.setEnabled(true, for: "codex")    // already enabled (empty suite): a no-op

        wait(for: [notPosted], timeout: 0.2)
    }

    func testOnProviderEnabledFiresOnEnableOnly() {
        // Wired to clear the failure backoff; must fire on a real enable, never on disable or a no-op.
        let store = ProviderEnablementStore(defaults: makeDefaults("on-enable"))
        var enabledIDs: [String] = []
        store.onProviderEnabled = { enabledIDs.append($0) }

        store.setEnabled(false, for: "codex")   // disable: must NOT fire
        store.setEnabled(true, for: "codex")    // enable: fires with "codex"
        store.setEnabled(true, for: "codex")    // already enabled (no-op): must NOT fire

        XCTAssertEqual(enabledIDs, ["codex"])
    }

    // MARK: - Enabled-list mode (fresh installs)

    func testSeedingSwitchesToEnabledListMode() {
        let defaults = makeDefaults("seed")
        let store = ProviderEnablementStore(defaults: defaults)

        store.seedEnabledProviders(["claude", "codex"])

        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("codex"))
        XCTAssertFalse(store.isEnabled("grok"))
        // The key property of enabled-list mode: a provider shipped later defaults to OFF.
        XCTAssertFalse(store.isEnabled("a-provider-that-ships-next-year"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.enabledIDs, ["claude", "codex"])
        XCTAssertTrue(reloaded.isEnabled("claude"))
        XCTAssertFalse(reloaded.isEnabled("grok"))
    }

    func testTogglesPersistInEnabledListMode() {
        let defaults = makeDefaults("enabled-toggles")
        let store = ProviderEnablementStore(defaults: defaults)
        store.seedEnabledProviders(["claude"])

        store.setEnabled(true, for: "grok")
        store.setEnabled(false, for: "claude")

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.enabledIDs, ["grok"])
        XCTAssertTrue(reloaded.isEnabled("grok"))
        XCTAssertFalse(reloaded.isEnabled("claude"))
    }

    func testReseedFiresOnProviderEnabledForNewlyOnOnly() {
        let store = ProviderEnablementStore(defaults: makeDefaults("reseed-enable"))
        store.seedEnabledProviders(["claude", "codex"])
        var enabledIDs: [String] = []
        store.onProviderEnabled = { enabledIDs.append($0) }

        // The detection pass replacing the fallback: codex stays on (no callback), grok turns on.
        store.seedEnabledProviders(["codex", "grok"])

        XCTAssertEqual(enabledIDs, ["grok"])
    }

    func testNoOpReseedDoesNotNotify() {
        let store = ProviderEnablementStore(defaults: makeDefaults("reseed-noop"))
        store.seedEnabledProviders(["claude"])
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.seedEnabledProviders(["claude"])

        wait(for: [notPosted], timeout: 0.2)
    }

    func testLegacyModeIgnoresEnabledListUntilSeeded() {
        // An existing install (disabled-list mode) must keep its semantics: absent enabled key means
        // everything is on except the explicitly disabled IDs.
        let defaults = makeDefaults("legacy-untouched")
        defaults.set(["devin"], forKey: "openusage.disabledProviders.v1")
        let store = ProviderEnablementStore(defaults: defaults)

        XCTAssertNil(store.enabledIDs)
        XCTAssertFalse(store.isEnabled("devin"))
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
    }

    // MARK: - Known-provider set

    func testRegisterKnownProvidersReturnsNewOnesAndPersists() {
        let defaults = makeDefaults("known")
        let store = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(store.knownIDs.isEmpty)

        XCTAssertEqual(store.registerKnownProviders(["claude", "codex"]), ["claude", "codex"])
        XCTAssertEqual(store.registerKnownProviders(["claude", "grok"]), ["grok"], "only never-seen IDs")
        XCTAssertEqual(store.registerKnownProviders(["claude"]), [], "no-op re-registration")

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.knownIDs, ["claude", "codex", "grok"])
    }

    func testRegisterKnownProvidersDoesNotTouchEnablement() {
        // Pure bookkeeping: registering must not flip any toggle or wake the refresh loop.
        let store = ProviderEnablementStore(defaults: makeDefaults("known-pure"))
        store.seedEnabledProviders(["claude"])
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.registerKnownProviders(["claude", "grok"])

        XCTAssertEqual(store.enabledIDs, ["claude"])
        XCTAssertFalse(store.isEnabled("grok"))
        wait(for: [notPosted], timeout: 0.2)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        makeScratchDefaults(suiteName: "OpenUsageTests.Enablement.\(name).\(UUID().uuidString)")
    }
}
