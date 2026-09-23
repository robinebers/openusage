import XCTest
@testable import OpenUsage

/// Settings → Privacy → Hide Emails. The masked shape matches Ghostex: first and last characters of
/// the local part survive, every domain becomes the same placeholder.
final class EmailMaskTests: XCTestCase {

    func testKeepsFirstAndLastLocalCharactersAndHidesTheDomain() {
        XCTAssertEqual(EmailMask.mask("jane@example.com"), "j•••e@•••••.•••")
    }

    func testSingleCharacterLocalPartKeepsOnlyThatCharacter() {
        XCTAssertEqual(EmailMask.mask("a@b.co"), "a•••@•••••.•••")
    }

    func testEveryDomainLooksTheSameSoNoneLeaks() {
        XCTAssertEqual(
            EmailMask.mask("dev42@gmail.com").split(separator: "@").last,
            EmailMask.mask("dev42@company.io").split(separator: "@").last
        )
    }

    func testParenthesesAroundAnAddressSurvive() {
        // Provider names wrap the email in parentheses; the closing one must not be eaten.
        XCTAssertEqual(
            EmailMask.mask("Claude: Acme (jane@example.com)"),
            "Claude: Acme (j•••e@•••••.•••)"
        )
    }

    func testPossessiveAfterAnAddressSurvives() {
        XCTAssertEqual(
            EmailMask.mask("Claude: dev42@gmail.com's Organization"),
            "Claude: d•••2@•••••.•••'s Organization"
        )
    }

    func testMasksEveryAddressInTheText() {
        XCTAssertEqual(
            EmailMask.mask("Claude: dev42@gmail.com's Organization (dev42@gmail.com)"),
            "Claude: d•••2@•••••.•••'s Organization (d•••2@•••••.•••)"
        )
    }

    func testDottedAndTaggedLocalPartsMaskWhole() {
        XCTAssertEqual(EmailMask.mask("first.last+ou@mail.example.org"), "f•••u@•••••.•••")
    }

    func testPunctuationAllowedInALocalPartMasksWhole() {
        // RFC 5322 allows these unquoted, and the account loaders accept them, so none may leak.
        XCTAssertEqual(EmailMask.mask("jane.smith!@example.com"), "j•••!@•••••.•••")
        XCTAssertEqual(EmailMask.mask("jane.smith#work@example.com"), "j•••k@•••••.•••")
        XCTAssertEqual(EmailMask.mask("jane.o'connor@example.com"), "j•••r@•••••.•••")
        XCTAssertEqual(EmailMask.mask("a/b=c?d^e`f{g|h}i~j$k&l*m@example.com"), "a•••m@•••••.•••")
    }

    func testPunctuationInALocalPartKeepsSurroundingTextIntact() {
        XCTAssertEqual(
            EmailMask.mask("Codex: Acme (jane.o'connor@example.com)"),
            "Codex: Acme (j•••r@•••••.•••)"
        )
        XCTAssertEqual(
            EmailMask.mask("Claude: jane#work@example.com's Organization"),
            "Claude: j•••k@•••••.•••'s Organization"
        )
    }

    func testTextWithoutAnEmailIsUnchanged() {
        XCTAssertEqual(EmailMask.mask("Codex: Workspace 1234abcd"), "Codex: Workspace 1234abcd")
        XCTAssertEqual(EmailMask.mask("Cursor"), "Cursor")
        XCTAssertEqual(EmailMask.mask(""), "")
    }

    func testAnAtSignWithoutADomainIsNotAnEmail() {
        XCTAssertEqual(EmailMask.mask("team@home"), "team@home")
    }

    func testTheSettingIsOffUntilTheUserTurnsItOn() {
        XCTAssertFalse(HideEmailsSetting.fallback)
    }
}
