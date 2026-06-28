import XCTest
@testable import OpenUsage

/// The transparency precedence rules: the egg wins regardless of the system accessibility flags (it's an
/// opt-in cheat code) — the secret code is the readable `disco`, "Even More" is the unreadable `ghost` —
/// while the proper "Increase Transparency" toggle yields to those flags.
final class PopoverTransparencyStyleTests: XCTestCase {
    private func resolve(increase: Bool, secretCode: Bool, evenMore: Bool,
                         reduceTransparency: Bool, increaseContrast: Bool) -> PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increase,
            secretCodeActive: secretCode,
            evenMore: evenMore,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    func testDefaultIsOpaque() {
        XCTAssertEqual(resolve(increase: false, secretCode: false, evenMore: false,
                               reduceTransparency: false, increaseContrast: false), .opaque)
    }

    func testProperToggleIncreasesWhenNoSystemFlags() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, evenMore: false,
                               reduceTransparency: false, increaseContrast: false), .increased)
    }

    func testProperToggleYieldsToReduceTransparency() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, evenMore: false,
                               reduceTransparency: true, increaseContrast: false), .opaque)
    }

    func testProperToggleYieldsToIncreaseContrast() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, evenMore: false,
                               reduceTransparency: false, increaseContrast: true), .opaque)
    }

    func testSecretCodeIsDiscoEvenWhenProperToggleIsOff() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, evenMore: false,
                               reduceTransparency: false, increaseContrast: false), .disco)
    }

    func testEvenMoreIsGhost() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, evenMore: true,
                               reduceTransparency: false, increaseContrast: false), .ghost)
    }

    func testEggIgnoresAccessibilityFlags() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, evenMore: false,
                               reduceTransparency: true, increaseContrast: true), .disco)
        XCTAssertEqual(resolve(increase: true, secretCode: true, evenMore: true,
                               reduceTransparency: true, increaseContrast: true), .ghost)
    }

    func testSurfaceTreatmentPerStyle() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.surfaceTreatment, .opaque)
        XCTAssertEqual(PopoverTransparencyStyle.increased.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.disco.surfaceTreatment, .scrim)
        XCTAssertEqual(PopoverTransparencyStyle.ghost.surfaceTreatment, .translucent)
    }

    func testWindowAlphaKeepsDiscoReadableAndGhostFaintest() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.windowAlpha, 1)
        XCTAssertEqual(PopoverTransparencyStyle.increased.windowAlpha, 1)
        XCTAssertGreaterThan(PopoverTransparencyStyle.disco.windowAlpha, 0.85)   // stays readable
        XCTAssertLessThan(PopoverTransparencyStyle.ghost.windowAlpha,
                          PopoverTransparencyStyle.disco.windowAlpha)            // faintest of all
    }

    func testShadowDroppedOnlyForGhost() {
        XCTAssertTrue(PopoverTransparencyStyle.opaque.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.increased.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.disco.wantsShadow)
        XCTAssertFalse(PopoverTransparencyStyle.ghost.wantsShadow)
    }
}
