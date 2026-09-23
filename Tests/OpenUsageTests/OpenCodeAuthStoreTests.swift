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
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
            databasePaths: { [] }
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
        XCTAssertTrue(try store(#"{"openai":{"type":"oauth","access":"access-token","refresh":"refresh-token"}}"#).hasCodexOAuth())
        XCTAssertTrue(try store(#"{"openai":{"type":"oauth","access":"access-token"}}"#).hasCodexOAuth())
    }

    func testDoesNotTreatOpenAIAPIKeyAsCodexOAuth() throws {
        XCTAssertFalse(try store(#"{"openai":{"type":"api","key":"sk-openai"}}"#).hasCodexOAuth())
        XCTAssertFalse(try store(#"{"openai":{"type":"oauth","access":" ","refresh":" "}}"#).hasCodexOAuth())
        XCTAssertFalse(try store(#"{"anthropic":{"type":"oauth","access":"token"}}"#).hasCodexOAuth())
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

    func testGoAPIKeyFallsBackToCredentialTableWhenAuthFileAbsent() throws {
        // OpenCode 2 moved credentials out of auth.json; an absent file must still find the DB key.
        XCTAssertEqual(try credentialStore(credentials: ["/oc/opencode.db": "sk-db-key"]).goAPIKey(), "sk-db-key")
    }

    func testGoAPIKeyPrefersDatabaseOverStaleAuthFile() throws {
        // OpenCode 2 imports auth.json without deleting it: after rotation the file holds sk-old
        // while SQLite holds sk-new, and the live row must win.
        let files = FakeFiles(["/oc/auth.json": #"{"opencode-go":{"type":"api","key":"sk-old"}}"#])
        XCTAssertEqual(
            try credentialStore(files: files, credentials: ["/oc/opencode.db": "sk-new"]).goAPIKey(),
            "sk-new"
        )
    }

    func testGoAPIKeyFallsBackToAuthFileWithoutDatabaseCredential() throws {
        // OpenCode 1 has no credential table, so the file remains the source there.
        XCTAssertEqual(try store(#"{"opencode-go":{"type":"api","key":"sk-file"}}"#).goAPIKey(), "sk-file")
    }

    func testHasCodexOAuthFallsBackToCredentialTable() throws {
        XCTAssertTrue(
            try credentialStore(credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"a","refresh":"r"}"#])
                .hasCodexOAuth()
        )
    }

    func testCredentialTableAPIKeyIsNotCodexOAuth() throws {
        XCTAssertFalse(
            try credentialStore(credentials: ["/oc/opencode.db": #"{"type":"key","key":"sk-x"}"#]).hasCodexOAuth()
        )
    }

    func testHasCodexOAuthPrefersDatabaseOverStaleAuthFile() throws {
        // The live row is an API key while the retained file still claims OAuth: not OAuth.
        let files = FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"a","refresh":"r"}}"#])
        XCTAssertFalse(
            try credentialStore(files: files, credentials: ["/oc/opencode.db": #"{"type":"key","key":"sk-x"}"#])
                .hasCodexOAuth()
        )
        // And the reverse: a stale file key must not hide a live OAuth credential.
        let keyFiles = FakeFiles(["/oc/auth.json": #"{"openai":{"type":"api","key":"sk-x"}}"#])
        XCTAssertTrue(
            try credentialStore(files: keyFiles, credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"a","refresh":"r"}"#])
                .hasCodexOAuth()
        )
    }

    func testOpenAICredentialReportsCreationTime() throws {
        // The Codex scanner bounds v2 rows to the OAuth credential's age; file credentials predate it.
        let db = credentialStore(
            credentials: ["/oc/opencode.db": #"{"type":"oauth","access":"a","refresh":"r"}"#],
            credentialTimes: ["/oc/opencode.db": "1786487065715"]
        )
        let status = try db.openAICredential()
        XCTAssertTrue(status.isOAuth)
        XCTAssertEqual(status.since.map(\.timeIntervalSince1970), 1786487065.715)

        let file = try store(#"{"openai":{"type":"oauth","access":"a","refresh":"r"}}"#).openAICredential()
        XCTAssertTrue(file.isOAuth)
        XCTAssertNil(file.since)
    }

    func testCredentialFallbackQueriesSelectTheCurrentRow() {
        // Superseded rows stay in the table, so every lookup must take the current row first —
        // OpenCode's own ordering — and admit NULL-flagged imports rather than requiring active = 1.
        for sql in [
            OpenCodeAuthStore.credentialSQLGoKey,
            OpenCodeAuthStore.credentialSQLOpencodeKey,
            OpenCodeAuthStore.credentialSQLCurrentOpenAI,
            OpenCodeAuthStore.credentialSQLCurrentOpenAITime,
        ] {
            XCTAssertTrue(sql.contains("(active IS NULL OR active = 1)"), sql)
            XCTAssertTrue(sql.contains("ORDER BY active DESC, time_updated DESC, id DESC"), sql)
        }
    }

    func testCredentialFallbackQueriesAreScopedToOpenCodeIntegrations() {
        // Both queries must name their integration — an unscoped LIKE 'sk-%' could hand goAPIKey()
        // a BYO key to send as a Bearer token.
        XCTAssertTrue(OpenCodeAuthStore.credentialSQLGoKey.contains("integration_id = 'opencode-go'"))
        XCTAssertTrue(OpenCodeAuthStore.credentialSQLOpencodeKey.contains("integration_id = 'opencode'"))
        XCTAssertFalse(OpenCodeAuthStore.credentialSQLOpencodeKey.contains("openai"))
    }

    func testCredentialDatabaseFailuresReturnNilInsteadOfThrowing() throws {
        // A locked or unreadable database reads as "not stored there", never as a throw — the failure
        // is logged and the scanner reports `databaseUnreadable` itself.
        let store = OpenCodeAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
            sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertNil(try store.goAPIKey())
        XCTAssertFalse(try store.hasCodexOAuth())
    }

    private func credentialStore(
        files: TextFileAccessing = FakeFiles(),
        credentials: [String: String],
        credentialTimes: [String: String] = [:]
    ) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
            sqlite: OpenCodeFakeSQLite(credentials: credentials, credentialTimes: credentialTimes),
            databasePaths: { ["/oc/opencode.db"] }
        )
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
