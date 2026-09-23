import XCTest
@testable import OpenUsage

/// How multi-account cards name themselves in a 320pt header: the account first, and no generated
/// wording that repeats it.
final class AccountDisplayNameTests: XCTestCase {

    // MARK: - Claude organizations

    func testPersonalOrganizationCollapsesToItsOwnersAddress() {
        // Anthropic names a personal organization after its owner, which says nothing the address
        // doesn't, and it is the half that survives truncation.
        XCTAssertEqual(
            ClaudeOrganizationLabel.collapsingDefaultName("jane@example.com's Organization"),
            "jane@example.com"
        )
    }

    func testTypographicApostropheIsCollapsedToo() {
        XCTAssertEqual(
            ClaudeOrganizationLabel.collapsingDefaultName("jane@example.com\u{2019}s Organization"),
            "jane@example.com"
        )
    }

    func testSuffixMatchIsCaseInsensitive() {
        XCTAssertEqual(
            ClaudeOrganizationLabel.collapsingDefaultName("jane@example.com's organization"),
            "jane@example.com"
        )
    }

    func testRealTeamNameIsUntouched() {
        XCTAssertEqual(ClaudeOrganizationLabel.collapsingDefaultName("Acme"), "Acme")
        XCTAssertEqual(ClaudeOrganizationLabel.collapsingDefaultName("Acme Research"), "Acme Research")
    }

    func testTeamNamedAfterAPersonKeepsItsName() {
        // Only an email-shaped owner counts as the generated form.
        XCTAssertEqual(
            ClaudeOrganizationLabel.collapsingDefaultName("Dave's Organization"),
            "Dave's Organization"
        )
        XCTAssertEqual(
            ClaudeOrganizationLabel.collapsingDefaultName("The Bakery's Organization"),
            "The Bakery's Organization"
        )
    }

    func testOwnerWithoutADottedDomainIsNotAnAddress() {
        XCTAssertEqual(
            ClaudeOrganizationLabel.collapsingDefaultName("team@intranet's Organization"),
            "team@intranet's Organization"
        )
    }

    // MARK: - Claude cards

    func testPersonalAccountIsNamedAfterItsAddress() {
        let account = claude(email: "jane@example.com", organizationName: "jane@example.com's Organization")

        XCTAssertEqual(account.displayName(), "Claude: jane@example.com")
    }

    func testTeamAccountIsNamedAfterItsAddressToo() {
        // The organization is not what tells two of your own accounts apart, and it crowded out the
        // address it was printed beside.
        let account = claude(email: "jane@example.com", organizationName: "Acme")

        XCTAssertEqual(account.displayName(), "Claude: jane@example.com")
    }

    func testOrganizationNameIsStillCarriedForTheRestOfTheApp() {
        XCTAssertEqual(claude(email: "jane@example.com", organizationName: "Acme").organizationName, "Acme")
    }

    // MARK: - Codex workspaces

    func testCodexIsNamedAfterTheAddressWithNoGeneratedWorkspace() {
        // The workspace id is generated, so it must not be what a narrow header spends its width on.
        let identity = CodexAccountIdentity(accountID: "0e1e7f6e-1234", email: "jane@example.com")

        XCTAssertEqual(identity?.displayName(), "Codex: jane@example.com")
    }

    func testTwoWorkspacesOnOneAddressGetTheirWorkspaceBack() {
        // Named by address alone the two would be identical, so the assembly asks for the workspace.
        let first = CodexAccountIdentity(accountID: "0e1e7f6e-1111", email: "jane@example.com")
        let second = CodexAccountIdentity(accountID: "b5a0767a-2222", email: "jane@example.com")

        XCTAssertEqual(first?.displayName(), second?.displayName())
        XCTAssertEqual(first?.displayName(disambiguatingWorkspace: true), "Codex: jane@example.com (Workspace 0e1e7f6e)")
        XCTAssertNotEqual(first?.displayName(disambiguatingWorkspace: true),
                          second?.displayName(disambiguatingWorkspace: true))
    }

    func testAliasWinsEvenWhenDisambiguating() {
        let identity = CodexAccountIdentity(accountID: "0e1e7f6e-1234", email: "jane@example.com")

        XCTAssertEqual(identity?.displayName(alias: "work", disambiguatingWorkspace: true),
                       "Codex: work (jane@example.com)")
    }

    func testAliasWinsOverBothWhenTheUserPickedOne() {
        let identity = CodexAccountIdentity(accountID: "0e1e7f6e-1234", email: "jane@example.com")

        XCTAssertEqual(identity?.displayName(alias: "work"), "Codex: work (jane@example.com)")
    }

    func testWorkspaceAloneWhenThereIsNoAddress() {
        let identity = CodexAccountIdentity(accountID: "0e1e7f6e-1234", email: nil)

        XCTAssertEqual(identity?.displayName(), "Codex: Workspace 0e1e7f6e")
    }

    func testAddressAloneWhenThereIsNoWorkspace() {
        let identity = CodexAccountIdentity(accountID: nil, email: "jane@example.com")

        XCTAssertEqual(identity?.displayName(), "Codex: jane@example.com")
    }

    // MARK: - Helpers

    private func claude(email: String, organizationName: String?) -> ClaudeSwapAccount {
        ClaudeSwapAccount(
            root: "/tmp/root", slot: "1", email: email,
            identityKey: "identity", organizationID: "org-1234abcd",
            organizationName: organizationName
        )
    }
}
