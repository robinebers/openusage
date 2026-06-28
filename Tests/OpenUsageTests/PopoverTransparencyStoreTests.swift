import XCTest
@testable import OpenUsage

@MainActor
final class PopoverTransparencyStoreTests: XCTestCase {
    /// Isolated, throwaway defaults per test (pattern from `RefreshSettingTests`).
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Transparency.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testIncreaseTransparencyDefaultsOff() {
        let store = PopoverTransparencyStore(defaults: makeDefaults("default"))
        XCTAssertFalse(store.increaseTransparency)
    }

    func testIncreaseTransparencyPersists() {
        let defaults = makeDefaults("persist")
        PopoverTransparencyStore(defaults: defaults).increaseTransparency = true
        // A fresh store reading the same defaults sees the saved value.
        XCTAssertTrue(PopoverTransparencyStore(defaults: defaults).increaseTransparency)
    }

    func testEggStateIsNeverPersisted() {
        let defaults = makeDefaults("ephemeral")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.toggleSecretCode()
        store.evenMore = true
        XCTAssertTrue(store.secretCodeActive)
        // The egg is ephemeral: a fresh store (a relaunch) starts clean.
        let reloaded = PopoverTransparencyStore(defaults: defaults)
        XCTAssertFalse(reloaded.secretCodeActive)
        XCTAssertFalse(reloaded.evenMore)
    }

    func testTurningEggOffClearsEvenMore() {
        let store = PopoverTransparencyStore(defaults: makeDefaults("evenmore"))
        store.toggleSecretCode()        // on
        store.evenMore = true
        store.toggleSecretCode()        // off
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertFalse(store.evenMore, "Even More clears when the egg turns off")
    }

    func testEffectiveStyleFollowsEgg() {
        // The egg path ignores the system accessibility flags, so these are deterministic on any host.
        let store = PopoverTransparencyStore(defaults: makeDefaults("style"))
        store.toggleSecretCode()        // secret code -> readable disco
        XCTAssertEqual(store.effectiveStyle, .disco)
        XCTAssertEqual(store.surfaceTreatment, .scrim)
        store.evenMore = true           // Even More -> unreadable ghost
        XCTAssertEqual(store.effectiveStyle, .ghost)
        store.toggleSecretCode()        // off; proper toggle is off too -> opaque regardless of host flags
        XCTAssertEqual(store.effectiveStyle, .opaque)
        XCTAssertEqual(store.surfaceTreatment, .opaque)
    }
}
