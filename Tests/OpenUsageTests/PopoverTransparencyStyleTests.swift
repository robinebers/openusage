import XCTest
@testable import OpenUsage

/// The transparency precedence rules: the egg wins regardless of the system accessibility flags (it's an
/// opt-in cheat code), while the proper "Increase Transparency" toggle yields to them.
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

    func testEggGhostsEvenWhenProperToggleIsOff() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, evenMore: false,
                               reduceTransparency: false, increaseContrast: false), .ghost)
    }

    func testEvenMoreIsGhostMore() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, evenMore: true,
                               reduceTransparency: false, increaseContrast: false), .ghostMore)
    }

    func testEggIgnoresAccessibilityFlags() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, evenMore: false,
                               reduceTransparency: true, increaseContrast: true), .ghost)
        XCTAssertEqual(resolve(increase: true, secretCode: true, evenMore: true,
                               reduceTransparency: true, increaseContrast: true), .ghostMore)
    }

    func testSurfaceTreatmentPerStyle() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.surfaceTreatment, .opaque)
        XCTAssertEqual(PopoverTransparencyStyle.increased.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.ghost.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.ghostMore.surfaceTreatment, .translucent)
    }

    func testWindowAlphaPerStyle() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.windowAlpha, 1)
        XCTAssertEqual(PopoverTransparencyStyle.increased.windowAlpha, 1)
        XCTAssertLessThan(PopoverTransparencyStyle.ghost.windowAlpha, 1)
        XCTAssertLessThan(PopoverTransparencyStyle.ghostMore.windowAlpha,
                          PopoverTransparencyStyle.ghost.windowAlpha)
    }

    func testShadowDroppedOnlyForGhostModes() {
        XCTAssertTrue(PopoverTransparencyStyle.opaque.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.increased.wantsShadow)
        XCTAssertFalse(PopoverTransparencyStyle.ghost.wantsShadow)
        XCTAssertFalse(PopoverTransparencyStyle.ghostMore.wantsShadow)
    }
}
