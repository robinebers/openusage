import XCTest
@testable import OpenUsage

/// How a card header names a provider, and what "Hide Agent Name for Multi-Account Card Headers"
/// drops when it is on.
final class ProviderHeaderNameTests: XCTestCase {

    // MARK: - Splitting the agent prefix off a multi-account name

    func testClaudeAccountNameLosesItsAgentPrefix() {
        let provider = make(id: "claude@3ac4b63e", name: "Claude: Acme (jane@example.com)")

        XCTAssertEqual(provider.accountLabel, "Acme (jane@example.com)")
    }

    func testCodexWorkspaceNameLosesItsAgentPrefix() {
        let provider = make(id: "codex@98e49fc0", name: "Codex: a@b.com (Workspace 1234abcd)")

        XCTAssertEqual(provider.accountLabel, "a@b.com (Workspace 1234abcd)")
    }

    func testSingleAccountProviderHasNoPrefixToDrop() {
        XCTAssertNil(make(id: "claude", name: "Claude").accountLabel)
        XCTAssertNil(make(id: "cursor", name: "Cursor").accountLabel)
    }

    func testOnlyTheProvidersOwnAgentCountsAsAPrefix() {
        // A colon in some other provider's name is not an agent prefix, so nothing is stripped.
        XCTAssertNil(make(id: "cursor", name: "Status: Degraded").accountLabel)
        XCTAssertNil(make(id: "codex", name: "Claude: Something").accountLabel)
    }

    func testColonInsideTheAccountLabelSurvives() {
        // Only the first ": " is the prefix boundary, and only when it follows the agent name, so an
        // aliased workspace keeps every word of its own label.
        let provider = make(id: "codex@85f9782d", name: "Codex: Work: Main (a@b.com)")

        XCTAssertEqual(provider.accountLabel, "Work: Main (a@b.com)")
    }

    func testPrefixWithNothingAfterItIsNotALabel() {
        XCTAssertNil(make(id: "claude@abc", name: "Claude: ").accountLabel)
    }

    func testPrefixMatchIsCaseInsensitive() {
        XCTAssertEqual(make(id: "Claude@abc", name: "claude: Team").accountLabel, "Team")
    }

    func testClaudeDesktopOrganizationNameLosesItsAgentPrefix() {
        // Desktop organization cards name themselves with an em dash rather than a colon.
        let provider = make(id: "claude@7f3e2a10", name: "Claude \u{2014} Acme Research")

        XCTAssertEqual(provider.accountLabel, "Acme Research")
    }

    func testColonInsideAnEmDashNamedAccountSurvives() {
        let provider = make(id: "claude@7f3e2a10", name: "Claude \u{2014} Acme: Research")

        XCTAssertEqual(provider.accountLabel, "Acme: Research")
    }

    // MARK: - What the header renders

    func testHeaderKeepsTheFullNameWhileTheSettingIsOff() {
        let provider = make(id: "claude@3ac4b63e", name: "Claude: Acme (jane@example.com)")

        XCTAssertEqual(
            provider.headerName(hidingAgentName: false),
            "Claude: Acme (jane@example.com)"
        )
    }

    func testHeaderDropsTheAgentWhileTheSettingIsOn() {
        let provider = make(id: "claude@3ac4b63e", name: "Claude: Acme (jane@example.com)")

        XCTAssertEqual(provider.headerName(hidingAgentName: true), "Acme (jane@example.com)")
    }

    func testSingleAccountHeaderIsUnchangedEitherWay() {
        let provider = make(id: "cursor", name: "Cursor")

        XCTAssertEqual(provider.headerName(hidingAgentName: true), "Cursor")
        XCTAssertEqual(provider.headerName(hidingAgentName: false), "Cursor")
    }

    func testTheSettingIsOffUntilTheUserTurnsItOn() {
        XCTAssertFalse(HideAgentNameSetting.fallback)
    }

    // MARK: - Hide Emails layered on top

    func testHeaderMasksTheEmailLeftAfterDroppingTheAgent() {
        let provider = make(id: "claude@3ac4b63e", name: "Claude: Acme (jane@example.com)")

        XCTAssertEqual(
            provider.headerName(hidingAgentName: true, hidingEmails: true),
            "Acme (j•••e@•••••.•••)"
        )
    }

    func testHeaderMasksTheEmailWhileKeepingTheAgent() {
        let provider = make(id: "claude@3ac4b63e", name: "Claude: Acme (jane@example.com)")

        XCTAssertEqual(
            provider.headerName(hidingAgentName: false, hidingEmails: true),
            "Claude: Acme (j•••e@•••••.•••)"
        )
    }

    func testOtherSurfacesOnlyMaskEmailsAndNeverDropTheAgent() {
        let provider = make(id: "codex@98e49fc0", name: "Codex: a.b@c.com (Workspace 1234abcd)")

        XCTAssertEqual(provider.visibleName(hidingEmails: true), "Codex: a•••b@•••••.••• (Workspace 1234abcd)")
        XCTAssertEqual(provider.visibleName(hidingEmails: false), "Codex: a.b@c.com (Workspace 1234abcd)")
    }

    // MARK: - Helpers

    private func make(id: String, name: String) -> Provider {
        Provider(id: id, displayName: name, icon: .providerMark("claude"))
    }
}
