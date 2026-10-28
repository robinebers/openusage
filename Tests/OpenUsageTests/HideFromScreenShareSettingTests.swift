import XCTest
@testable import OpenUsage

@MainActor
final class HideFromScreenShareSettingTests: XCTestCase {
    func testUsageIsConcealedOnlyWhileTheSettingIsOnAndTheScreenIsCaptured() {
        for (enabled, captured) in [(true, true), (true, false), (false, true)] {
            let watched = TestSwitch(false)
            let setting = HideFromScreenShareSetting(
                defaults: isolatedDefaults(),
                isScreenCaptured: { captured },
                installChangeNotifications: { _ in watched.value = true }
            )
            XCTAssertFalse(setting.isEnabled, "off by default")
            setting.isEnabled = enabled

            XCTAssertEqual(setting.isConcealing, enabled && captured, "on: \(enabled), captured: \(captured)")
            XCTAssertEqual(watched.value, enabled, "the capture is watched only while the setting is on")
        }
    }

    func testTheSettingReadsAndWritesTheKeyVersion0716Saved() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "hideUsageWhileScreenSharing")
        let setting = HideFromScreenShareSetting(defaults: defaults, isScreenCaptured: { true }, installChangeNotifications: { _ in })
        XCTAssertTrue(setting.isEnabled)
        XCTAssertTrue(setting.isConcealing, "a saved setting conceals from launch")

        setting.isEnabled = false
        XCTAssertEqual(defaults.object(forKey: "hideUsageWhileScreenSharing") as? Bool, false)
        XCTAssertFalse(setting.isConcealing, "turning it off shows usage at once")
    }
}
