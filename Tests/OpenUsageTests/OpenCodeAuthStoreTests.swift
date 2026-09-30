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

    private let stable = "/oc/opencode.db"

    private func credentialStore(
        files: TextFileAccessing = FakeFiles(),
        credentials: [String: String] = [:],
        credentialTimes: [String: String] = [:],
        failing: Set<String> = []
    ) -> OpenCodeAuthStore {
        openCodeAuthStore(
            files: files,
            sqlite: OpenCodeFakeSQLite(failing: failing, credentials: credentials, credentialTimes: credentialTimes)
        )
    }

    /// `auth.json`-only stores see an OpenCode 1 database: the fake has no `credential` table there.
    private func openAICredential(_ store: OpenCodeAuthStore) throws -> OpenCodeAuthStore.OpenAICredential {
        try store.openAICredential(databasePath: stable)
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
        XCTAssertTrue(try openAICredential(store(#"{"openai":{"type":"oauth","access":"access-token","refresh":"refresh-token"}}"#)).isOAuth)
        XCTAssertTrue(try openAICredential(store(#"{"openai":{"type":"oauth","access":"access-token"}}"#)).isOAuth)
    }

    func testDoesNotTreatOpenAIAPIKeyAsCodexOAuth() throws {
        XCTAssertFalse(try openAICredential(store(#"{"openai":{"type":"api","key":"sk-openai"}}"#)).isOAuth)
        XCTAssertFalse(try openAICredential(store(#"{"openai":{"type":"oauth","access":" ","refresh":" "}}"#)).isOAuth)
        XCTAssertFalse(try openAICredential(store(#"{"anthropic":{"type":"oauth","access":"token"}}"#)).isOAuth)
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
        XCTAssertTrue(try openAICredential(credentialStore(
            credentials: [stable: #"{"type":"oauth","access":"token"}"#]
        )).isOAuth)
    }

    func testCredentialTableAPIKeyIsNotCodexOAuth() throws {
        XCTAssertFalse(try openAICredential(credentialStore(
            credentials: [stable: #"{"type":"key","key":"sk-x"}"#]
        )).isOAuth)
    }

    func testHasCodexOAuthPrefersDatabaseOverStaleAuthFile() throws {
        XCTAssertFalse(try openAICredential(credentialStore(
            files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"stale","refresh":"stale"}}"#]),
            credentials: [stable: #"{"type":"key","key":"sk-x"}"#]
        )).isOAuth)
        XCTAssertTrue(try openAICredential(credentialStore(
            files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"api","key":"sk-x"}}"#]),
            credentials: [stable: #"{"type":"oauth","access":"token"}"#]
        )).isOAuth)
    }

    func testEmptyCredentialTableDoesNotFallBackToStaleAuthFile() throws {
        // OpenCode 2 logout deletes the `openai` row but leaves the imported auth.json behind. An
        // existing table with no row is "logged out", unlike an OpenCode 1 database with no table.
        let staleFile = FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"stale","refresh":"stale"}}"#])
        XCTAssertFalse(try openAICredential(credentialStore(files: staleFile, credentials: [stable: ""])).isOAuth)
        XCTAssertTrue(try openAICredential(credentialStore(files: staleFile)).isOAuth)
    }

    func testOpenAICredentialReportsCreationTime() throws {
        let fromDatabase = try openAICredential(credentialStore(
            credentials: [stable: #"{"type":"oauth","access":"token"}"#],
            credentialTimes: [stable: "1786487065715"]
        ))
        XCTAssertTrue(fromDatabase.isOAuth)
        XCTAssertEqual(
            try XCTUnwrap(fromDatabase.since).timeIntervalSince1970,
            1_786_487_065.715,
            accuracy: 0.000_000_1
        )

        let fromFile = try openAICredential(store(#"{"openai":{"type":"oauth","access":"token"}}"#))
        XCTAssertTrue(fromFile.isOAuth)
        XCTAssertNil(fromFile.since)
    }

    func testImplausibleCredentialTimestampIsAReadFailureNotATrap() {
        // `Int(Double)` traps past `Int.max`; a nonsense time_created must surface as a logged
        // failure for that database instead of crashing the refresh.
        for raw in ["1e300", "-1", "9223372036854775808"] {
            XCTAssertThrowsError(try openAICredential(credentialStore(
                credentials: [stable: #"{"type":"oauth","access":"token"}"#],
                credentialTimes: [stable: raw]
            )), raw) { error in
                guard case OpenCodeUsageError.credentialsUnreadable = error else {
                    return XCTFail("expected credentialsUnreadable, got \(error)")
                }
            }
        }
    }

    func testCredentialFallbackQueriesSelectTheCurrentRow() {
        let sql = OpenCodeAuthStore.credentialSQLCurrentOpenAI
        XCTAssertTrue(sql.contains("(active IS NULL OR active = 1)"), sql)
        XCTAssertTrue(sql.contains("ORDER BY active DESC, time_updated DESC, id DESC"), sql)
        XCTAssertTrue(sql.contains("json_array"), sql)
    }

    func testEachChannelDatabaseIsJudgedByItsOwnCredential() throws {
        // OpenCode partitions credentials by release channel: a stable API key says nothing about a
        // preview OAuth login, and vice versa.
        let store = credentialStore(credentials: [
            "/oc/opencode-next.db": #"{"type":"oauth","access":"live"}"#,
            stable: #"{"type":"key","key":"sk-x"}"#
        ])
        XCTAssertTrue(try store.openAICredential(databasePath: "/oc/opencode-next.db").isOAuth)
        XCTAssertFalse(try store.openAICredential(databasePath: stable).isOAuth)
    }

    func testCredentialDatabaseFailureThrowsInsteadOfFallingBackToStaleAuthFile() {
        // A locked database is not "no credential": throwing keeps the caller from reading the
        // retained auth.json in its place.
        XCTAssertThrowsError(try openAICredential(credentialStore(
            files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"stale","refresh":"stale"}}"#]),
            failing: [stable]
        )))
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
