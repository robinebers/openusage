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

    /// A store on throwaway defaults with the accessibility flags pinned (both off by default), so the
    /// egg's resolved style is deterministic regardless of the test host's real accessibility settings.
    private func makeStore(_ name: String,
                           reduceTransparency: Bool = false,
                           increaseContrast: Bool = false) -> PopoverTransparencyStore {
        PopoverTransparencyStore(defaults: makeDefaults(name),
                                 reduceTransparency: reduceTransparency,
                                 increaseContrast: increaseContrast)
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
        let store = makeStore("drunk")
        store.toggleSecretCode()        // on
        store.drunkMode = true
        store.toggleSecretCode()        // off
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertFalse(store.drunkMode, "Drunk Mode clears when the egg turns off")
    }

    // MARK: - Party Mode toggle / state machine (Normal 1, Increase Transparency 2, Party 3, Drunk 4)

    func testPartyModeToggleMirrorsTheEgg() {
        let store = makeStore("partyMirror")
        XCTAssertFalse(store.partyModeActive)
        store.toggleSecretCode()                    // cheat code in
        XCTAssertTrue(store.partyModeActive, "Party Mode reads the egg state")
        store.partyModeActive = false               // toggle off == exit
        XCTAssertFalse(store.secretCodeActive)
    }

    func testPartyToggleOffFromState3ReturnsToBase() {
        // Base 1 (Increase Transparency off): 1 -> 3 -> 1. Egg off + base off is opaque on any host.
        let store = makeStore("p3base1")
        store.toggleSecretCode()                    // 1 -> 3
        XCTAssertEqual(store.effectiveStyle, .party)
        store.partyModeActive = false               // 3 -> 1
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testPartyToggleOffFromState4ClearsDrunkAndReturnsToBase() {
        // 1 -> 3 -> 4, then Party off goes 4 -> base (NOT 4 -> 3), clearing Drunk along the way.
        let store = makeStore("p4base1")
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
        let store = makeStore("d4to3")
        store.toggleSecretCode()                    // 1 -> 3
        store.drunkMode = true                       // 3 -> 4
        store.drunkMode = false                      // 4 -> 3
        XCTAssertTrue(store.secretCodeActive, "still in the party")
        XCTAssertEqual(store.effectiveStyle, .party)
    }

    func testBase2PartyRendersAndReturnsToIncreaseTransparency() {
        // Direct 2 -> 3 -> 2: the egg renders the readable party with base 2 (deterministic here because
        // the store pins the accessibility flags off), and exiting restores base 2.
        let store = makeStore("base2party")
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
        // base, not effectiveStyle.)
        let store = makeStore("remember")
        store.increaseTransparency = true            // base 2
        store.toggleSecretCode()                     // 2 -> 3
        store.drunkMode = true                        // 3 -> 4
        store.partyModeActive = false                // 4 -> base
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertTrue(store.increaseTransparency, "the prior base (Increase Transparency) is restored")
    }

    func testEffectiveStyleFollowsEgg() {
        // With the accessibility flags pinned off, the egg resolves to the readable party / drunk.
        let store = makeStore("style")
        store.toggleSecretCode()        // secret code -> readable party
        XCTAssertEqual(store.effectiveStyle, .party)
        XCTAssertEqual(store.surfaceTreatment, .translucent)
        store.drunkMode = true          // Drunk Mode -> woozy, barely-readable drunk
        XCTAssertEqual(store.effectiveStyle, .drunk)
        store.toggleSecretCode()        // off; proper toggle is off too -> opaque
        XCTAssertEqual(store.effectiveStyle, .opaque)
        XCTAssertEqual(store.surfaceTreatment, .opaque)
    }

    // MARK: - Accessibility clamp (the egg yields to Reduce Transparency / Increase Contrast)

    func testEggYieldsToReduceTransparency() {
        // With Reduce Transparency on, entering the code keeps the panel opaque — the egg may not turn it
        // translucent — and escalating to Drunk Mode doesn't change that.
        let store = makeStore("eggA11yReduce", reduceTransparency: true)
        store.toggleSecretCode()
        XCTAssertTrue(store.secretCodeActive, "the egg is active as state")
        XCTAssertEqual(store.effectiveStyle, .opaque, "but it renders opaque, yielding to the flag")
        XCTAssertEqual(store.surfaceTreatment, .opaque)
        store.drunkMode = true
        XCTAssertEqual(store.effectiveStyle, .opaque, "drunk is clamped too — no window fade")
    }

    func testEggYieldsToIncreaseContrast() {
        let store = makeStore("eggA11yContrast", increaseContrast: true)
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testPartyPausedReflectsAccessibility() {
        // No flags: the party renders, so it's not paused.
        let clear = makeStore("partyPausedClear")
        clear.toggleSecretCode()
        XCTAssertFalse(clear.partyPaused)
        // A flag on while the egg is active: paused, so Settings can explain the normal-looking panel.
        let reduced = makeStore("partyPausedReduce", reduceTransparency: true)
        reduced.toggleSecretCode()
        XCTAssertTrue(reduced.partyPaused)
        // A flag on but no egg: not "party paused" (that notice is egg-specific).
        let noEgg = makeStore("partyPausedNoEgg", increaseContrast: true)
        XCTAssertFalse(noEgg.partyPaused)
    }
}
