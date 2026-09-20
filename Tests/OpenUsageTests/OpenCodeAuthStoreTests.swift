import XCTest
@testable import OpenUsage

/// Go-key detection from `auth.json`, including tolerance of unrelated sibling entries (regression for the
/// atomic-decode gap that let one odd top-level value hide a valid `opencode-go` key) and the
/// broken-storage-is-not-logout distinction (unreadable/malformed files throw instead of reading as nil).
final class OpenCodeAuthStoreTests: XCTestCase {
    private func store(_ json: String) -> OpenCodeAuthStore {
        store(files: FakeFiles(["/oc/auth.json": json]))
    }

    private func store(files: TextFileAccessing) -> OpenCodeAuthStore {
        openCodeAuthStore(files: files)
    }

    private func credentialStore(
        files: TextFileAccessing = FakeFiles(),
        credentials: [String: String] = [:],
        credentialTimes: [String: String] = [:],
        failing: Set<String> = [],
        databasePaths: [String] = ["/oc/opencode.db"]
    ) -> OpenCodeAuthStore {
        openCodeAuthStore(
            files: files,
            sqlite: OpenCodeFakeSQLite(failing: failing, credentials: credentials, credentialTimes: credentialTimes),
            databasePaths: databasePaths
        )
    }

    func testReadsGoKey() throws {
        XCTAssertEqual(try store(#"{"opencode-go":{"type":"api","key":"sk-abc"}}"#).goAPIKey(), "sk-abc")
    }

    func testToleratesNonObjectSiblingEntries() throws {
        // A future schema marker (string) and an array entry beside opencode-go must not hide the key.
        let json = #"{"$schema":"https://opencode.ai/auth.json","opencode-go":{"type":"api","key":"sk-xyz"},"weird":["a","b"]}"#
        XCTAssertEqual(try store(json).goAPIKey(), "sk-xyz")
    }

    func testCoexistsWithOtherProviderEntries() throws {
        let json = #"{"openai":{"type":"oauth","access":"x","refresh":"y"},"opencode-go":{"type":"api","key":"sk-1"}}"#
        XCTAssertEqual(try store(json).goAPIKey(), "sk-1")
    }

    func testDetectsCodexOAuthWithoutExposingTokens() throws {
        XCTAssertTrue(try store(#"{"openai":{"type":"oauth","access":"access-token","refresh":"refresh-token"}}"#).openAICredential().isOAuth)
        XCTAssertTrue(try store(#"{"openai":{"type":"oauth","access":"access-token"}}"#).openAICredential().isOAuth)
    }

    func testDoesNotTreatOpenAIAPIKeyAsCodexOAuth() throws {
        XCTAssertFalse(try store(#"{"openai":{"type":"api","key":"sk-openai"}}"#).openAICredential().isOAuth)
        XCTAssertFalse(try store(#"{"openai":{"type":"oauth","access":" ","refresh":" "}}"#).openAICredential().isOAuth)
        XCTAssertFalse(try store(#"{"anthropic":{"type":"oauth","access":"token"}}"#).openAICredential().isOAuth)
    }

    func testMissingEmptyOrAbsentKeyIsNil() throws {
        XCTAssertNil(try store(#"{"opencode-go":{"type":"api"}}"#).goAPIKey())
        XCTAssertNil(try store(#"{"opencode-go":{"type":"api","key":"   "}}"#).goAPIKey())
        XCTAssertNil(try store(#"{"openai":{"type":"oauth"}}"#).goAPIKey())
        XCTAssertNil(try store(files: FakeFiles()).goAPIKey()) // absent file = not logged in
    }

    func testMalformedJSONThrowsCredentialsUnreadable() {
        XCTAssertThrowsError(try store("not json").goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testUnreadablePresentFileThrowsCredentialsUnreadable() {
        // A present auth.json that can't be read (permissions, encoding) must not masquerade as logout.
        XCTAssertThrowsError(try store(files: UnreadableFiles(present: ["/oc/auth.json"])).goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testHasCodexOAuthFallsBackToCredentialTable() throws {
        XCTAssertTrue(try credentialStore(
            credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"token"}"#]
        ).openAICredential().isOAuth)
    }

    func testCredentialTableAPIKeyIsNotCodexOAuth() throws {
        XCTAssertFalse(try credentialStore(
            credentials: ["/oc/opencode.db": #"{"type":"key","key":"sk-x"}"#]
        ).openAICredential().isOAuth)
    }

    func testHasCodexOAuthPrefersDatabaseOverStaleAuthFile() throws {
        XCTAssertFalse(try credentialStore(
            files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"stale","refresh":"stale"}}"#]),
            credentials: ["/oc/opencode.db": #"{"type":"key","key":"sk-x"}"#]
        ).openAICredential().isOAuth)
        XCTAssertTrue(try credentialStore(
            files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"api","key":"sk-x"}}"#]),
            credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"token"}"#]
        ).openAICredential().isOAuth)
    }

    func testOpenAICredentialReportsCreationTime() throws {
        let fromDatabase = try credentialStore(
            credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"token"}"#],
            credentialTimes: ["/oc/opencode.db": "1786487065715"]
        ).openAICredential()
        XCTAssertTrue(fromDatabase.isOAuth)
        XCTAssertEqual(
            try XCTUnwrap(fromDatabase.since).timeIntervalSince1970,
            1_786_487_065.715,
            accuracy: 0.000_000_1
        )

        let fromFile = try store(#"{"openai":{"type":"oauth","access":"token"}}"#).openAICredential()
        XCTAssertTrue(fromFile.isOAuth)
        XCTAssertNil(fromFile.since)
    }

    func testCredentialFallbackQueriesSelectTheCurrentRow() {
        let sql = OpenCodeAuthStore.credentialSQLCurrentOpenAI
        XCTAssertTrue(sql.contains("(active IS NULL OR active = 1)"), sql)
        XCTAssertTrue(sql.contains("ORDER BY active DESC, time_updated DESC, id DESC"), sql)
        XCTAssertTrue(sql.contains("json_array"), sql)
    }

    func testCurrentCredentialIsChosenAcrossChannelDatabases() throws {
        // Path-sorted discovery visits opencode-next.db first. A leftover preview OAuth row must
        // not beat a later stable API key, or zero-cost stable history would be attributed to Codex.
        let nextOAuth = #"[ {"type":"oauth","access":"stale"}, 1, 5, "next", 100 ]"#
        let stableKey = #"[ {"type":"key","key":"sk-x"}, 1, 9, "stable", 200 ]"#
        XCTAssertFalse(try credentialStore(
            credentials: [
                "/oc/opencode-next.db": nextOAuth,
                "/oc/opencode.db": stableKey
            ],
            databasePaths: ["/oc/opencode-next.db", "/oc/opencode.db"]
        ).openAICredential().isOAuth)
        XCTAssertTrue(try credentialStore(
            credentials: [
                "/oc/opencode-next.db": #"[ {"type":"key","key":"sk-old"}, 1, 5, "next", 100 ]"#,
                "/oc/opencode.db": #"[ {"type":"oauth","access":"live"}, 1, 9, "stable", 200 ]"#
            ],
            databasePaths: ["/oc/opencode-next.db", "/oc/opencode.db"]
        ).openAICredential().isOAuth)
    }

    func testCredentialDatabaseFailuresReturnNilInsteadOfThrowing() throws {
        XCTAssertFalse(try credentialStore(failing: ["/oc/opencode.db"]).openAICredential().isOAuth)
    }

    func testCredentialDatabaseFailureDoesNotFallBackToStaleAuthFile() throws {
        XCTAssertFalse(try credentialStore(
            files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"stale","refresh":"stale"}}"#]),
            failing: ["/oc/opencode.db"]
        ).openAICredential().isOAuth)
    }
}

/// A file store whose present files exist but always fail to read, like a permission-denied auth.json.
final class UnreadableFiles: TextFileAccessing, @unchecked Sendable {
    let present: Set<String>
    init(present: Set<String>) { self.present = present }

    func exists(_ path: String) -> Bool { present.contains(path) }
    func readText(_ path: String) throws -> String {
        throw CocoaError(.fileReadNoPermission)
    }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}
