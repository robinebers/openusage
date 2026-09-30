import Observation
import XCTest
@testable import OpenUsage

/// The screen-share privacy contract: usage is concealed exactly when the setting is on AND a capture
/// is active — never from either alone — the preference persists, and turning the setting off clears
/// the capture state immediately (no wordmark lingering after opt-out).
@MainActor
final class MenuBarPrivacyStoreTests: XCTestCase {
    /// Isolated, throwaway defaults per test (pattern from `PopoverTransparencyStoreTests`).
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.MenuBarPrivacy.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// A store with the capture probe pinned to `captured`'s live value and notifications stubbed out,
    /// so tests never touch the real window server.
    private func makeStore(
        _ name: String,
        defaults: UserDefaults? = nil,
        captured: @escaping @MainActor () -> Bool
    ) -> MenuBarPrivacyStore {
        MenuBarPrivacyStore(
            defaults: defaults ?? makeDefaults(name),
            probe: captured,
            installChangeNotifications: { _ in }
        )
    }

    func testDefaultsOffAndNotConcealing() {
        let store = makeStore("default", captured: { true })
        XCTAssertFalse(store.hideUsageWhileScreenSharing)
        XCTAssertFalse(store.screenIsCaptured)
        XCTAssertFalse(store.concealUsage)
    }

    func testCaptureAndSettingAloneNeverConceal() {
        for (captured, enabled) in [(true, false), (false, true)] {
            let store = makeStore("capture\(captured)-enabled\(enabled)", captured: { captured })
            store.hideUsageWhileScreenSharing = enabled
            store.refreshCaptureState()
            XCTAssertFalse(store.concealUsage)
        }
    }

    func testEnablingDuringCaptureConcealsImmediately() {
        let store = makeStore("enableDuringCapture", captured: { true })
        store.hideUsageWhileScreenSharing = true
        XCTAssertTrue(store.screenIsCaptured, "Enabling runs an immediate check, not just the poll")
        XCTAssertTrue(store.concealUsage)
    }

    func testConcealFollowsCaptureTransitions() {
        // A reference box rather than a captured `var` — the probe closure crosses into the store,
        // and mutating a captured local after a sendable capture warns under strict concurrency.
        final class CaptureFlag { var isOn = false }
        let capture = CaptureFlag()
        let store = makeStore("transitions", captured: { capture.isOn })
        store.hideUsageWhileScreenSharing = true
        XCTAssertFalse(store.concealUsage)

        capture.isOn = true
        store.refreshCaptureState()
        XCTAssertTrue(store.concealUsage)

        capture.isOn = false
        store.refreshCaptureState()
        XCTAssertFalse(store.concealUsage)
    }

    func testDisablingClearsCaptureStateAndRejectsStaleNotifications() {
        let store = makeStore("disableClears", captured: { true })
        store.hideUsageWhileScreenSharing = true
        XCTAssertTrue(store.concealUsage)

        store.hideUsageWhileScreenSharing = false
        XCTAssertFalse(store.screenIsCaptured, "Opting out must drop the wordmark without waiting for a poll")
        XCTAssertFalse(store.concealUsage)

        store.refreshCaptureState()
        XCTAssertFalse(store.concealUsage, "A stale capture notification cannot reconceal after opt-out")
    }

    func testSettingPersistsAcrossStores() {
        let defaults = makeDefaults("persist")
        makeStore("persistFirst", defaults: defaults, captured: { true }).hideUsageWhileScreenSharing = true

        // A fresh store on the same defaults reads the saved value and arms monitoring right away
        // (the persisted-on launch path, which bypasses `didSet`).
        let relaunched = makeStore("persistSecond", defaults: defaults, captured: { true })
        XCTAssertTrue(relaunched.hideUsageWhileScreenSharing)
        XCTAssertTrue(relaunched.concealUsage)
    }


    // MARK: - Hide Emails

    func testHideEmailsDefaultsOffAndPersists() {
        let defaults = makeDefaults("hideEmails")
        let store = makeStore("hideEmails", defaults: defaults, captured: { false })
        XCTAssertFalse(store.hideEmails)
        store.hideEmails = true
        XCTAssertTrue(defaults.bool(forKey: HideEmailsSetting.key), "Views read the same key via @AppStorage")
        XCTAssertTrue(makeStore("hideEmails.reload", defaults: defaults, captured: { false }).hideEmails)
    }

    func testResetTurnsBothPrivacySettingsOff() {
        // Regression: Reset All Settings left Hide Emails on.
        let defaults = makeDefaults("reset")
        let store = makeStore("reset", defaults: defaults, captured: { false })
        store.hideUsageWhileScreenSharing = true
        store.hideEmails = true
        store.resetToDefaults()
        XCTAssertFalse(store.hideUsageWhileScreenSharing)
        XCTAssertFalse(store.hideEmails)
        XCTAssertFalse(defaults.bool(forKey: HideEmailsSetting.key))
    }

    func testTogglingHideEmailsRerendersTheMenuBarSummary() {
        // Regression: the menu bar read Hide Emails straight from defaults, which its observation
        // loop can't see, so VoiceOver kept announcing the full address after the toggle.
        let store = makeStore("menuBar", captured: { false })
        let provider = Provider(id: "claude@1", displayName: "Claude: jane@example.com", icon: .providerMark("claude"))
        let metric = WidgetDescriptor(
            id: "claude@1.session", providerID: provider.id, metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: .providerMark("claude"), kind: .percent, used: 25, limit: 100)
        )
        let groups = [ProviderMetrics(provider: provider, metrics: [metric])]
        final class Flag: @unchecked Sendable { var fired = false }
        let changed = Flag()
        let before = withObservationTracking {
            MenuBarContentBuilder.build(groups: groups, hidingEmails: store.hideEmails, data: { $0.sample })
        } onChange: {
            changed.fired = true
        }
        XCTAssertEqual(before.accessibilityText, "Claude: jane@example.com Session 25%")

        store.hideEmails = true

        XCTAssertTrue(changed.fired, "The menu bar's render loop must re-arm on the toggle")
        let after = MenuBarContentBuilder.build(groups: groups, hidingEmails: store.hideEmails, data: { $0.sample })
        XCTAssertEqual(after.accessibilityText, "Claude: j•••e@•••••.••• Session 25%")
    }
}
