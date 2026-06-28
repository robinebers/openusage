import XCTest
@testable import OpenUsage

/// The transparency precedence rules: the egg wins regardless of the system accessibility flags (it's an
/// opt-in cheat code) — the secret code is the readable `party`, "Drunk Mode" is the barely-readable
/// `drunk` — while the proper "Increase Transparency" toggle yields to those flags.
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

    func testEggIgnoresAccessibilityFlags() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: true, increaseContrast: true), .party)
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: true,
                               reduceTransparency: true, increaseContrast: true), .drunk)
    }

    func testSurfaceTreatmentPerStyle() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.surfaceTreatment, .opaque)
        XCTAssertEqual(PopoverTransparencyStyle.increased.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.party.surfaceTreatment, .scrim)
        XCTAssertEqual(PopoverTransparencyStyle.drunk.surfaceTreatment, .translucent)
    }

    func testWindowAlphaKeepsPartyReadableAndDrunkFaintest() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.windowAlpha, 1)
        XCTAssertEqual(PopoverTransparencyStyle.increased.windowAlpha, 1)
        XCTAssertGreaterThan(PopoverTransparencyStyle.party.windowAlpha, 0.85)    // stays readable
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
