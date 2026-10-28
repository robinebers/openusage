import XCTest
@testable import OpenUsage

@MainActor
final class HideFromScreenShareSettingTests: XCTestCase {
    private let usage = MenuBarContent(groups: [MenuBarContent.Group(
        provider: Provider(id: "test", kind: .claude),
        metrics: [MenuBarContent.Metric(id: "test.session", label: "Session", value: "42%")]
    )])

    func testTheMenuBarShowsTheMarkOnlyWhileTheSettingIsOnAndTheScreenIsCaptured() {
        for (enabled, captured) in [(true, true), (true, false), (false, true)] {
            let watched = TestSwitch(false)
            let setting = HideFromScreenShareSetting(
                defaults: isolatedDefaults(),
                isScreenCaptured: { captured },
                installChangeNotifications: { _ in watched.value = true }
            )
            XCTAssertFalse(setting.isEnabled, "off by default")
            setting.isEnabled = enabled

            let content = setting.menuBarContent { usage }
            XCTAssertEqual(MenuBarStripRenderer.image(for: content) == nil, enabled && captured, "on: \(enabled), captured: \(captured)")
            XCTAssertEqual(watched.value, enabled, "the capture is watched only while the setting is on")
        }
    }

    func testTheSettingReadsAndWritesTheKeyVersion0716Saved() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "hideUsageWhileScreenSharing")
        let setting = HideFromScreenShareSetting(defaults: defaults, isScreenCaptured: { true }, installChangeNotifications: { _ in })
        XCTAssertTrue(setting.isEnabled)
        XCTAssertTrue(setting.menuBarContent { usage }.isEmpty, "a saved setting conceals from launch")

        setting.isEnabled = false
        XCTAssertEqual(defaults.object(forKey: "hideUsageWhileScreenSharing") as? Bool, false)
        XCTAssertEqual(setting.menuBarContent { usage }, usage, "turning it off shows usage at once")
    }
}
