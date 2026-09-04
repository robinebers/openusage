import Foundation
import XCTest
@testable import OpenUsage

final class ClaudeDesktopTokenCacheTests: XCTestCase {
    private let account = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private let otherAccount = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    private let organization = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let otherOrganization = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAccountPrefixedTokensWorkInEitherCacheVersion() throws {
        let cache = [scopedKey(): token("scoped")]
        for useV2 in [false, true] {
            let result = select(v2: useV2 ? cache : nil, v1: useV2 ? nil : cache)
            let oauth = try available(result)
            XCTAssertEqual(oauth.accessToken, "scoped")
            XCTAssertNil(oauth.refreshToken)
        }
    }

    func testLegacyKeysRemainUsableWithoutAccountMetadata() throws {
        let result = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization, v2: [legacyKey(): token("legacy")], v1: nil, now: now
        )
        XCTAssertEqual(try available(result).accessToken, "legacy")
    }

    func testScopedKeysRequireTheMatchingValidAccount() {
        for currentAccount: String? in [nil, "", "invalid", otherAccount] {
            let result = ClaudeDesktopAuthStore.selectCredential(
                activeOrganization: organization, activeAccountUUID: currentAccount,
                v2: [scopedKey(): token("foreign")], v1: nil, now: now
            )
            assertNotFound(result)
        }
    }

    func testAccountAndOrganizationUUIDMatchingIgnoresCase() throws {
        let result = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization.uppercased(), activeAccountUUID: account.uppercased(),
            v2: ["acct:\(account.uppercased())|\(client.uppercased()):\(organization.uppercased()):https://api.anthropic.com:user:profile": token("scoped")],
            v1: nil, now: now
        )
        XCTAssertEqual(try available(result).accessToken, "scoped")
    }

    func testMalformedPrefixesAndKeysAreRejected() {
        for key in [
            "acct:|\(legacyKey())", "acct:not-a-uuid|\(legacyKey())",
            "acct:\(account)\(legacyKey())", "acct:\(account)||\(legacyKey())",
            "acct:\(account)|acct:\(account)|\(legacyKey())", "acct:\(account)|",
            "acct:\(account)|not-a-client:\(organization):https://api.anthropic.com:user:profile"
        ] {
            assertNotFound(select(v2: [key: token("invalid")]))
        }
    }

    func testWrongOrganizationHostAndMissingProfileScopeAreRejected() {
        for key in [
            scopedKey(organization: otherOrganization),
            scopedKey().replacingOccurrences(of: "https://api.anthropic.com", with: "https://example.com"),
            scopedKey(scopes: "user:inference")
        ] {
            assertNotFound(select(v2: [key: token("ineligible")]))
        }
    }

    func testScopedEntrySupersedesLongerLivedLegacyAliasInEitherVersion() throws {
        let cache = [legacyKey(): token("old", expiresIn: 86_400), scopedKey(): token("current")]
        for useV2 in [false, true] {
            let result = select(v2: useV2 ? cache : nil, v1: useV2 ? nil : cache)
            XCTAssertEqual(try available(result).accessToken, "current")
        }
    }

    func testScopedDeletionMarkerSuppressesLegacyAliasInEitherVersion() {
        let cache: [String: Any] = [legacyKey(): token("old"), scopedKey(): NSNull()]
        for useV2 in [false, true] {
            assertNotFound(select(v2: useV2 ? cache : nil, v1: useV2 ? nil : cache))
        }
    }

    func testV2DeletionMarkersSuppressV1AcrossBothKeyFormats() {
        for v2Key in [legacyKey(), scopedKey()] {
            for v1Key in [legacyKey(), scopedKey()] {
                assertNotFound(select(v2: [v2Key: NSNull()], v1: [v1Key: token("old")]))
            }
        }
    }

    func testV2TokenTakesPrecedenceAcrossBothKeyFormats() throws {
        for v2Key in [legacyKey(), scopedKey()] {
            for v1Key in [legacyKey(), scopedKey()] {
                let result = select(v2: [v2Key: token("v2")], v1: [v1Key: token("v1", expiresIn: 86_400)])
                XCTAssertEqual(try available(result).accessToken, "v2")
            }
        }
    }

    func testForeignAccountCannotSupplyTokenOrSuppressCurrentAccountFallback() throws {
        let foreignKey = "acct:\(otherAccount)|\(legacyKey())"
        for entry: Any in [token("foreign", expiresIn: 86_400), NSNull()] {
            let result = select(v2: [foreignKey: entry], v1: [scopedKey(): token("current")])
            XCTAssertEqual(try available(result).accessToken, "current")
        }
    }

    func testExpiredScopedEntryDoesNotReviveLegacyOrV1Copy() {
        let result = select(
            v2: [scopedKey(): token("expired", expiresIn: -1), legacyKey(): token("legacy")],
            v1: [legacyKey(): token("v1")]
        )
        guard case .stale = result else { return XCTFail("Expected stale, got \(result)") }
    }

    func testScopedExpirySafetyMarginIsPreserved() {
        for expiresIn: TimeInterval in [-1, 0, 119, 120] {
            let result = select(v2: [scopedKey(): token("expiring", expiresIn: expiresIn)])
            guard case .stale = result else { return XCTFail("Expected stale, got \(result)") }
        }
    }

    func testInvalidScopedEntryDoesNotReviveLegacyAlias() {
        let result = select(v2: [scopedKey(): ["token": " "], legacyKey(): token("legacy")])
        guard case .invalid = result else { return XCTFail("Expected invalid, got \(result)") }
    }

    func testProductionFullScopeRankingIsPreservedForScopedKeys() throws {
        let result = select(v2: [
            scopedKey(scopes: "user:profile"): token("profile-only", expiresIn: 86_400),
            scopedKey(): token("full-scope", expiresIn: 300)
        ])
        XCTAssertEqual(try available(result).accessToken, "full-scope")
    }

    private func legacyKey(organization: String? = nil, scopes: String = "user:profile user:inference") -> String {
        "\(client):\(organization ?? self.organization):https://api.anthropic.com:\(scopes)"
    }

    private func scopedKey(organization: String? = nil, scopes: String = "user:profile user:inference") -> String {
        "acct:\(account)|\(legacyKey(organization: organization, scopes: scopes))"
    }

    private func token(_ value: String, expiresIn: TimeInterval = 3_600) -> [String: Any] {
        ["token": value, "refreshToken": "never-use-this", "expiresAt": (now.timeIntervalSince1970 + expiresIn) * 1000]
    }

    private func select(v2: [String: Any]?, v1: [String: Any]? = nil) -> ClaudeDesktopAuthStore.Selection {
        ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization, activeAccountUUID: account, v2: v2, v1: v1, now: now
        )
    }

    private func available(_ result: ClaudeDesktopAuthStore.Selection) throws -> ClaudeOAuth {
        guard case .available(let oauth) = result else {
            XCTFail("Expected available, got \(result)")
            throw ClaudeAuthError.notLoggedIn
        }
        return oauth
    }

    private func assertNotFound(_ result: ClaudeDesktopAuthStore.Selection, file: StaticString = #filePath, line: UInt = #line) {
        guard case .notFound = result else { return XCTFail("Expected not found, got \(result)", file: file, line: line) }
    }
}
