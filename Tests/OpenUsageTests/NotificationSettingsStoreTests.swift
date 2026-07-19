import XCTest
@testable import OpenUsage

@MainActor
final class NotificationSettingsStoreTests: XCTestCase {
    func testResetToDefaultsTurnsAllTriggersOffAndPersists() {
        let suiteName = "OpenUsageTests.notification-settings-reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = NotificationSettingsStore(defaults: defaults)
        store.underTenPercent = true
        store.healthyToClose = true
        store.closeToRunningOut = true

        store.resetToDefaults()

        XCTAssertFalse(store.anyEnabled)
        // A second store on the same suite must load the defaults back, not the pre-reset values.
        let reloaded = NotificationSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.underTenPercent)
        XCTAssertFalse(reloaded.healthyToClose)
        XCTAssertFalse(reloaded.closeToRunningOut)
    }
}
