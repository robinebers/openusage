import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class PrivacyModeSettingTests: XCTestCase {
    func testTheContainerPersistsPrivacyModeAndRestoresItOnRelaunch() {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        XCTAssertFalse(container.privacyMode.isEnabled)

        container.privacyMode.isEnabled = true
        XCTAssertTrue(defaults.bool(forKey: PrivacyModeSetting.key))
        XCTAssertTrue(PrivacyModeSetting(defaults: defaults).isEnabled)
        let relaunched = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        XCTAssertTrue(relaunched.privacyMode.isEnabled)

        relaunched.privacyMode.isEnabled = false
        XCTAssertFalse(defaults.bool(forKey: PrivacyModeSetting.key))
        XCTAssertFalse(PrivacyModeSetting(defaults: defaults).isEnabled)
    }

    func testEnablingPrivacyModeCancelsRenameAndRejectsStaleCommitsWithoutChangingTheSignIn() throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let credential = AccountCredential.apiKey("private-saved-key")
        let saved = accounts.add(kind: .claude, label: "private@example.com", credential: credential)
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        container.renaming.begin(saved.cardID)
        let edit = try XCTUnwrap(container.renaming.edit)
        container.renaming.draft = "unsaved-private-name"

        container.privacyMode.isEnabled = true
        XCTAssertNil(container.renaming.edit, "enabling the mode closes an editor that contains the private name")
        XCTAssertTrue(container.renaming.draft.isEmpty)
        container.renaming.commit(edit)
        container.renaming.begin(saved.cardID)
        XCTAssertNil(container.renaming.edit, "a rename command cannot reopen the private name while the mode is on")
        container.renaming.draft = "accidental-commit"
        container.renaming.commit()
        XCTAssertEqual(accounts.accounts, [saved])
        XCTAssertEqual(try vault.load(saved.id), credential)

        container.privacyMode.isEnabled = false
        container.renaming.begin(saved.cardID)
        XCTAssertEqual(container.renaming.draft, saved.label, "turning the mode off restores the saved name for editing")
        container.renaming.cancel()
        XCTAssertEqual(accounts.accounts, [saved])
        XCTAssertEqual(try vault.load(saved.id), credential)
    }

    func testTheMenuBarProjectionHidesIdentityAndInitialsWhilePreservingTheLimits() throws {
        let provider = Provider(
            id: "copilot@stable-account", kind: .copilot, accountLabel: "private@example.com",
            organization: "private-organization", hubHost: "private-hub.example.com", badge: "PE"
        )
        let masked = PrivacyModeSetting.provider(provider, isEnabled: true)
        let originalContent = menuBarContent(provider)
        let maskedContent = menuBarContent(masked)
        let originalItem = try XCTUnwrap(originalContent.items.first)
        let maskedItem = try XCTUnwrap(maskedContent.items.first)

        XCTAssertEqual(maskedItem.id, originalItem.id)
        XCTAssertEqual(maskedItem.provider.id, provider.id)
        XCTAssertEqual(maskedItem.provider.kind, provider.kind)
        XCTAssertEqual(maskedItem.label, originalItem.label)
        XCTAssertEqual(maskedItem.shortLabel, originalItem.shortLabel)
        XCTAssertEqual(maskedItem.value, originalItem.value, "the displayed usage stays real")
        XCTAssertEqual(maskedContent.overflow, originalContent.overflow)
        XCTAssertTrue(maskedContent.accessibilityText.contains(provider.displayName))
        XCTAssertTrue(maskedContent.accessibilityText.contains(originalItem.value))
        for privateText in ["private@example.com", "private-organization", "private-hub.example.com"] {
            XCTAssertFalse(maskedContent.accessibilityText.contains(privateText))
            XCTAssertFalse(masked.fullName.contains(privateText))
        }
        XCTAssertNotEqual(masked.badge, provider.badge, "the menu-bar mark cannot keep the account's real initials")
        XCTAssertNotNil(masked.badge)
        XCTAssertNil(masked.organization)
        XCTAssertNotEqual(masked.hubHost, provider.hubHost)
        XCTAssertEqual(PrivacyModeSetting.provider(provider, isEnabled: false), provider)
        XCTAssertEqual(provider.accountLabel, "private@example.com", "the display projection leaves the source untouched")
        XCTAssertNil(PrivacyModeSetting.provider(Provider(id: "claude@single", kind: .claude), isEnabled: true).badge,
                     "a sole account must not gain an unnecessary badge")
    }

    private func menuBarContent(_ provider: Provider) -> MenuBarContent {
        let data = WidgetData(title: "Session", kind: .percent, used: 95, limit: 100)
        let descriptor = WidgetDescriptor(provider: provider, key: "session", metricLabel: "Session", sample: data)
        let account = DashboardAccount(provider: provider, lines: [DashboardLine(descriptor: descriptor, data: data)])
        let board = PriorityBoard.make(accounts: [account], now: Date(timeIntervalSince1970: 1_800_000_000))
        return MenuBarContentBuilder.build(board: board, limit: .upToThree)
    }
}
