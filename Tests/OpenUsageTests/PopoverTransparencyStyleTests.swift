import XCTest
@testable import OpenUsage

/// The transparency precedence rules: Reduce Transparency / Increase Contrast clamp everything to opaque
/// first (an accessibility need, not a preference), so both the proper "Increase Transparency" toggle and
/// the secret-code egg yield to them. With the flags off the egg wins — the secret code is the readable
/// `party`, "Drunk Mode" the barely-readable `drunk`.
final class PopoverTransparencyStyleTests: XCTestCase {
    private func resolve(increase: Bool, secretCode: Bool, drunkMode: Bool,
                         reduceTransparency: Bool, increaseContrast: Bool) -> PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increase,
            secretCodeActive: secretCode,
            drunkMode: drunkMode,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    func testDefaultIsOpaque() {
        XCTAssertEqual(resolve(increase: false, secretCode: false, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .opaque)
    }

    func testProperToggleIncreasesWhenNoSystemFlags() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .increased)
    }

    func testProperToggleYieldsToReduceTransparency() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: false,
                               reduceTransparency: true, increaseContrast: false), .opaque)
    }

    func testProperToggleYieldsToIncreaseContrast() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: false,
                               reduceTransparency: false, increaseContrast: true), .opaque)
    }

    func testSecretCodeIsPartyEvenWhenProperToggleIsOff() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .party)
    }

    func testDrunkModeIsDrunk() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .drunk)
    }

    func testDrunkModeIsIgnoredWithoutTheSecretCode() {
        // Drunk can't exist without the party: with the code off, drunkMode is ignored entirely and the
        // resolved style is just the base (opaque or increased), never .drunk.
        XCTAssertEqual(resolve(increase: false, secretCode: false, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .opaque)
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .increased)
    }

    func testEggYieldsToAccessibilityFlags() {
        // Reduce Transparency / Increase Contrast are accessibility needs, so they clamp the panel to
        // opaque even when the secret code (and Drunk Mode) is active — the hidden egg may not override
        // them. Either flag alone is enough.
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: true, increaseContrast: false), .opaque)
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: false, increaseContrast: true), .opaque)
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: true,
                               reduceTransparency: true, increaseContrast: false), .opaque)
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: true,
                               reduceTransparency: true, increaseContrast: true), .opaque)
    }

    func testEggRendersWhenAccessibilityFlagsAreOff() {
        // With both flags off the egg still wins over the proper toggle.
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .party)
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .drunk)
    }

    func testSurfaceTreatmentPerStyle() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.surfaceTreatment, .opaque)
        XCTAssertEqual(PopoverTransparencyStyle.increased.surfaceTreatment, .translucent)
        // Party shares Increase Transparency's translucent foundation (the blurred desktop shows through,
        // tinted by the party gradient) rather than a distinct treatment.
        XCTAssertEqual(PopoverTransparencyStyle.party.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.drunk.surfaceTreatment, .translucent)
    }

    func testWindowAlphaKeepsPartyReadableAndDrunkFaintest() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.windowAlpha, 1)
        XCTAssertEqual(PopoverTransparencyStyle.increased.windowAlpha, 1)
        // Party keeps the window fully opaque like Increase Transparency — the desktop shows through the
        // translucent backdrop, not by fading the window (which would dim the text too).
        XCTAssertEqual(PopoverTransparencyStyle.party.windowAlpha, 1)
        XCTAssertLessThan(PopoverTransparencyStyle.drunk.windowAlpha,
                          PopoverTransparencyStyle.party.windowAlpha)             // faintest of all
    }

    func testShadowDroppedOnlyForDrunk() {
        XCTAssertTrue(PopoverTransparencyStyle.opaque.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.increased.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.party.wantsShadow)
        XCTAssertFalse(PopoverTransparencyStyle.drunk.wantsShadow)
    }
}
