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

    func testIncreaseTransparencyTogglesBackOffAndPersists() {
        // The normal 2 -> 1 direction: turning the base off again writes through (exercises the no-op
        // didSet guard in both directions) and a relaunch reads it back as off.
        let defaults = makeDefaults("toggleBack")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.increaseTransparency = true
        store.increaseTransparency = false
        XCTAssertFalse(PopoverTransparencyStore(defaults: defaults).increaseTransparency)
    }

    func testEggStateIsNeverPersisted() {
        let defaults = makeDefaults("ephemeral")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.toggleSecretCode()
        store.drunkMode = true
        XCTAssertTrue(store.secretCodeActive)
        // The egg is ephemeral: a fresh store (a relaunch) starts clean.
        let reloaded = PopoverTransparencyStore(defaults: defaults)
        XCTAssertFalse(reloaded.secretCodeActive)
        XCTAssertFalse(reloaded.drunkMode)
    }

    func testTurningEggOffClearsDrunkMode() {
        let store = PopoverTransparencyStore(defaults: makeDefaults("drunk"))
        store.toggleSecretCode()        // on
        store.drunkMode = true
        store.toggleSecretCode()        // off
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertFalse(store.drunkMode, "Drunk Mode clears when the egg turns off")
    }

    // MARK: - Party Mode toggle / state machine (Normal 1, Increase Transparency 2, Party 3, Drunk 4)

    func testPartyModeToggleMirrorsTheEgg() {
        let store = PopoverTransparencyStore(defaults: makeDefaults("partyMirror"))
        XCTAssertFalse(store.partyModeActive)
        store.toggleSecretCode()                    // cheat code in
        XCTAssertTrue(store.partyModeActive, "Party Mode reads the egg state")
        store.partyModeActive = false               // toggle off == exit
        XCTAssertFalse(store.secretCodeActive)
    }

    func testPartyToggleOffFromState3ReturnsToBase() {
        // Base 1 (Increase Transparency off): 1 -> 3 -> 1. Egg off + base off is opaque on any host.
        let store = PopoverTransparencyStore(defaults: makeDefaults("p3base1"))
        store.toggleSecretCode()                    // 1 -> 3
        XCTAssertEqual(store.effectiveStyle, .party)
        store.partyModeActive = false               // 3 -> 1
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testPartyToggleOffFromState4ClearsDrunkAndReturnsToBase() {
        // 1 -> 3 -> 4, then Party off goes 4 -> base (NOT 4 -> 3), clearing Drunk along the way.
        let store = PopoverTransparencyStore(defaults: makeDefaults("p4base1"))
        store.toggleSecretCode()                    // 1 -> 3
        store.drunkMode = true                       // 3 -> 4
        XCTAssertEqual(store.effectiveStyle, .drunk)
        store.partyModeActive = false               // 4 -> base
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertFalse(store.drunkMode, "can't be drunk without the party")
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testDrunkToggleOffStaysInPartyState3() {
        // The only way 4 -> 3 is turning Drunk off; the egg stays active.
        let store = PopoverTransparencyStore(defaults: makeDefaults("d4to3"))
        store.toggleSecretCode()                    // 1 -> 3
        store.drunkMode = true                       // 3 -> 4
        store.drunkMode = false                      // 4 -> 3
        XCTAssertTrue(store.secretCodeActive, "still in the party")
        XCTAssertEqual(store.effectiveStyle, .party)
    }

    func testBase2PartyRendersAndReturnsToIncreaseTransparency() {
        // Direct 2 -> 3 -> 2: the egg renders the readable party even with base 2 (deterministic on any
        // host because the egg path ignores the accessibility flags), and exiting restores base 2.
        let store = PopoverTransparencyStore(defaults: makeDefaults("base2party"))
        store.increaseTransparency = true            // base 2
        store.toggleSecretCode()                     // 2 -> 3
        XCTAssertEqual(store.effectiveStyle, .party)
        store.partyModeActive = false                // 3 -> 2
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertTrue(store.increaseTransparency, "base 2 restored")
    }

    func testBaseStateIsRememberedAcrossTheEgg() {
        // Older state memory: Increase Transparency (base 2) survives the whole 2 -> 3 -> 4 -> 2 round
        // trip untouched, because its Settings toggle is frozen while the egg runs. (Asserts the stored
        // base, not effectiveStyle, so it stays host-independent of the live accessibility flags.)
        let store = PopoverTransparencyStore(defaults: makeDefaults("remember"))
        store.increaseTransparency = true            // base 2
        store.toggleSecretCode()                     // 2 -> 3
        store.drunkMode = true                        // 3 -> 4
        store.partyModeActive = false                // 4 -> base
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertTrue(store.increaseTransparency, "the prior base (Increase Transparency) is restored")
    }

    func testEffectiveStyleFollowsEgg() {
        // The egg path ignores the system accessibility flags, so these are deterministic on any host.
        let store = PopoverTransparencyStore(defaults: makeDefaults("style"))
        store.toggleSecretCode()        // secret code -> readable party
        XCTAssertEqual(store.effectiveStyle, .party)
        XCTAssertEqual(store.surfaceTreatment, .translucent)
        store.drunkMode = true          // Drunk Mode -> woozy, barely-readable drunk
        XCTAssertEqual(store.effectiveStyle, .drunk)
        store.toggleSecretCode()        // off; proper toggle is off too -> opaque regardless of host flags
        XCTAssertEqual(store.effectiveStyle, .opaque)
        XCTAssertEqual(store.surfaceTreatment, .opaque)
    }
}
