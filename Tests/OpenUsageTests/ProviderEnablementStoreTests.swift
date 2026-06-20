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

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Enablement.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
