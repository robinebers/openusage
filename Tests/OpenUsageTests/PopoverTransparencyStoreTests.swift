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

    func testIncreaseTransparencyDefaultsOffAndPersistsBothTransitions() {
        let defaults = makeDefaults("persist")
        let store = PopoverTransparencyStore(defaults: defaults)
        XCTAssertFalse(store.increaseTransparency)

        store.increaseTransparency = true
        XCTAssertTrue(PopoverTransparencyStore(defaults: defaults).increaseTransparency)

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

    func testPartyModeReturnsToEitherPriorBaseStyle() {
        for increased in [false, true] {
            let store = makeStore(increased ? "partyIncreased" : "partyOpaque")
            store.increaseTransparency = increased
            XCTAssertFalse(store.partyModeActive)

            store.toggleSecretCode()
            XCTAssertTrue(store.partyModeActive)
            XCTAssertEqual(store.effectiveStyle, .party)

            store.partyModeActive = false
            XCTAssertFalse(store.secretCodeActive)
            XCTAssertEqual(store.increaseTransparency, increased)
            XCTAssertEqual(store.effectiveStyle, increased ? .increased : .opaque)
        }
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

    func testEggYieldsToEitherAccessibilitySetting() {
        for store in [
            makeStore("eggA11yReduce", reduceTransparency: true),
            makeStore("eggA11yContrast", increaseContrast: true)
        ] {
            store.toggleSecretCode()
            XCTAssertTrue(store.secretCodeActive)
            XCTAssertEqual(store.effectiveStyle, .opaque)
            XCTAssertEqual(store.surfaceTreatment, .opaque)

            store.drunkMode = true
            XCTAssertEqual(store.effectiveStyle, .opaque)
        }
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

    // MARK: - Egg animation gate (no animation work while the popover is hidden — PR #784)

    func testEggAnimationsInactiveWhileHidden() {
        // The egg is active but the popover is closed (default popoverShown == false): no loop mounts, so
        // no display link ticks. This is the ~30% idle-CPU regression the owner flagged on PR #784.
        let store = makeStore("animHidden")
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .party)
        XCTAssertFalse(store.eggAnimationsActive, "no animation while the popover is hidden")
        store.drunkMode = true
        XCTAssertEqual(store.effectiveStyle, .drunk)
        XCTAssertFalse(store.eggAnimationsActive, "drunk doesn't animate while hidden either")
    }

    func testEggAnimationsActiveOnInPlaceActivation() {
        // Popover already on-screen, then the code is entered: the loops must activate immediately — the
        // in-place-start guarantee the conditional mount restores over the reverted `.animation(paused:)`.
        let store = makeStore("animInPlace")
        store.setPopoverShown(true)
        XCTAssertFalse(store.eggAnimationsActive, "no egg yet")
        store.toggleSecretCode()
        XCTAssertTrue(store.eggAnimationsActive, "party animates the moment it's switched on while shown")
        store.drunkMode = true
        XCTAssertTrue(store.eggAnimationsActive, "drunk animates in place too")
    }

    func testEggAnimationsStopWhenPopoverHides() {
        // Shown + active, then the popover closes: the gate flips off so the loops unmount.
        let store = makeStore("animHide")
        store.setPopoverShown(true)
        store.toggleSecretCode()
        XCTAssertTrue(store.eggAnimationsActive)
        store.setPopoverShown(false)
        XCTAssertFalse(store.eggAnimationsActive, "closing the popover stops the animation")
    }

    func testEggAnimationsInactiveWithoutTheEgg() {
        // Shown but no egg: nothing animates — the loops exist only for the party/drunk styles.
        let store = makeStore("animNoEgg")
        store.setPopoverShown(true)
        XCTAssertFalse(store.eggAnimationsActive, "a normal popover never animates")
        store.increaseTransparency = true
        XCTAssertFalse(store.eggAnimationsActive, "Increase Transparency is static, not animated")
    }

    func testEggAnimationsYieldToAccessibilityClamp() {
        // The accessibility clamp resolves the egg to .opaque, so even shown + code-entered there's no
        // animation — consistent with the panel staying opaque.
        for store in [makeStore("animReduce", reduceTransparency: true),
                      makeStore("animContrast", increaseContrast: true)] {
            store.setPopoverShown(true)
            store.toggleSecretCode()
            store.drunkMode = true
            XCTAssertEqual(store.effectiveStyle, .opaque)
            XCTAssertFalse(store.eggAnimationsActive, "a clamped egg renders opaque, so nothing animates")
        }
    }

    func testPopoverShownIsNeverPersisted() {
        // popoverShown is runtime-transient like the egg: a fresh store (a relaunch) starts hidden.
        let defaults = makeDefaults("shownEphemeral")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.setPopoverShown(true)
        XCTAssertTrue(store.popoverShown)
        XCTAssertFalse(PopoverTransparencyStore(defaults: defaults).popoverShown, "not persisted")
    }

    func testResetToDefaultsTurnsOffTransparencyAndExitsTheEgg() {
        let defaults = makeDefaults("reset")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.increaseTransparency = true
        store.toggleSecretCode()
        store.drunkMode = true

        store.resetToDefaults()

        XCTAssertFalse(store.increaseTransparency)
        XCTAssertFalse(store.secretCodeActive, "reset exits the egg so it can't override the reset look")
        XCTAssertFalse(store.drunkMode)
        // A fresh store reading the same defaults sees the reset value.
        XCTAssertFalse(PopoverTransparencyStore(defaults: defaults).increaseTransparency)
    }
}
