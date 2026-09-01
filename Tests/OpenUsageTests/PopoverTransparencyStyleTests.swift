import XCTest
@testable import OpenUsage

/// The transparency precedence rules: Reduce Transparency / Increase Contrast clamp everything to opaque
/// first (an accessibility need, not a preference), so both the proper "Increase Transparency" toggle and
/// the secret-code egg yield to them. With the flags off the egg wins — the secret code is the readable
/// `party`, "Drunk Mode" the barely-readable `drunk`.
final class PopoverTransparencyStyleTests: XCTestCase {
    private func resolve(
        increase: Bool = false,
        secretCode: Bool = false,
        drunkMode: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increase,
            secretCodeActive: secretCode,
            drunkMode: drunkMode,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    func testBaseAndPartyStylesFollowSecretCodePrecedence() {
        XCTAssertEqual(resolve(), .opaque)
        XCTAssertEqual(resolve(increase: true), .increased)
        XCTAssertEqual(resolve(secretCode: true), .party)
        XCTAssertEqual(resolve(secretCode: true, drunkMode: true), .drunk)
        XCTAssertEqual(resolve(drunkMode: true), .opaque)
        XCTAssertEqual(resolve(increase: true, drunkMode: true), .increased)
        XCTAssertEqual(resolve(increase: true, secretCode: true), .party)
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: true), .drunk)
    }

    func testEitherAccessibilitySettingOverridesEveryTranslucentStyle() {
        for (reduce, contrast) in [(true, false), (false, true), (true, true)] {
            XCTAssertEqual(resolve(increase: true, reduceTransparency: reduce, increaseContrast: contrast), .opaque)
            XCTAssertEqual(resolve(secretCode: true, reduceTransparency: reduce, increaseContrast: contrast), .opaque)
            XCTAssertEqual(
                resolve(increase: true, secretCode: true, drunkMode: true,
                        reduceTransparency: reduce, increaseContrast: contrast),
                .opaque
            )
        }
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

    func testReadableTranslucentStylesReinforceChromeLegibility() {
        XCTAssertFalse(PopoverTransparencyStyle.opaque.needsChromeLegibilityBacking)
        XCTAssertTrue(PopoverTransparencyStyle.increased.needsChromeLegibilityBacking)
        XCTAssertTrue(PopoverTransparencyStyle.party.needsChromeLegibilityBacking)
        XCTAssertFalse(PopoverTransparencyStyle.drunk.needsChromeLegibilityBacking)
    }
}
