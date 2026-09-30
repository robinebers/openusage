import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeCredentialPreservationTests: XCTestCase {
    private let path = "/tmp/claude/.credentials.json"
    private let original = #"""
    {
      "claudeAiOauth": {
        "accessToken": "old-access",
        "refreshToken": "old-refresh",
        "expiresAt": 1,
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_5x",
        "scopes": ["user:profile"],
        "futureOAuthField": {"nested": [true, null, 42, "keep"], "enabled": false}
      },
      "mcpOAuth": {
        "synthetic-server": {"accessToken": "mcp-access", "refreshToken": "mcp-refresh", "expiresAt": 12345}
      },
      "futureTopLevel": {"array": [1, false, null, {"value": "keep"}], "largeInteger": 9007199254740993}
    }
    """#

    func testRotationPreservesCompleteDocumentInEveryWritableStore() throws {
        for storage in Storage.allCases {
            let fixture = makeFixture(storage: storage, document: original)
            let generation = fixture.store.credentialGeneration()
            var state = try XCTUnwrap(fixture.store.loadCredentialCandidates().first)
            state.oauth.accessToken = "new-access"
            state.oauth.refreshToken = "new-refresh"
            state.oauth.expiresAt = 4_102_444_800_000

            XCTAssertTrue(try fixture.store.save(state, ifUnchanged: generation))

            try assertDocument(fixture.document, preserves: original, rotated: state.oauth)
            XCTAssertEqual(fixture.store.credentialGeneration(), generation.replacing(state))
        }
    }

    func testRotationMergesLatestMCPChangesInEveryWritableStore() throws {
        for storage in Storage.allCases {
            let fixture = makeFixture(storage: storage, document: original)
            let generation = fixture.store.credentialGeneration()
            var state = try XCTUnwrap(fixture.store.loadCredentialCandidates().first)
            state.oauth.accessToken = "new-access"
            state.oauth.refreshToken = "new-refresh"
            state.oauth.expiresAt = 4_102_444_800_000
            let latest = try concurrentUpdate()
            fixture.setDocument(latest)

            XCTAssertNotEqual(fixture.store.loadCredentialCandidates().first?.fullData, state.fullData)
            XCTAssertEqual(fixture.store.credentialGeneration(), generation,
                           "MCP and unknown fields do not change the Claude login")
            XCTAssertTrue(try fixture.store.save(state, ifUnchanged: generation))

            try assertDocument(fixture.document, preserves: latest, rotated: state.oauth)
        }
    }

    func testInFlightRefreshPreservesConcurrentMCPUpdate() async throws {
        let fixture = makeFixture(storage: .currentUserKeychain, document: original)
        let latest = try concurrentUpdate()
        let keychain = fixture.keychain
        let service = fixture.service
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/v1/oauth/token":
                keychain.currentUserValues[service] = latest
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8
                ))
            case "/api/oauth/usage":
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00Z"}}"#.utf8
                ))
            case "/api/oauth/profile":
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            default:
                XCTFail("Unexpected request: \(request.url.path)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        let provider = ClaudeProvider(
            authStore: fixture.store,
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("Expected live usage after token rotation")
        }
        XCTAssertEqual(used, 25)
        let rotated = ClaudeOAuth(accessToken: "new-access", refreshToken: "new-refresh",
                                  expiresAt: (now.timeIntervalSince1970 + 3600) * 1000)
        try assertDocument(fixture.document, preserves: latest, rotated: rotated)
    }

    func testHexEncodedDocumentRetainsUnknownFieldsWhenSaved() throws {
        for prefix in ["", "0x", "0X"] {
            let hex = prefix + original.utf8.map { String(format: "%02x", $0) }.joined()
            let fixture = makeFixture(storage: .legacyKeychain, document: hex)
            let generation = fixture.store.credentialGeneration()
            var state = try XCTUnwrap(fixture.store.loadCredentialCandidates().first)
            state.oauth.accessToken = "new-access"

            XCTAssertTrue(try fixture.store.save(state, ifUnchanged: generation))

            try assertDocument(fixture.document, preserves: original, rotated: state.oauth)
        }
    }

    func testMergeDoesNotRewriteMetadataOrIntroduceAbsentFields() throws {
        let raw = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":null,"expiresAt":null,"scopes":null},"other":false}"#
        let document = try XCTUnwrap(ClaudeAuthStore.parseCredentials(raw))
        let oauth = ClaudeOAuth(accessToken: "new", subscriptionType: "unexpected", scopes: ["unexpected"])

        let saved = try document.mergingRotatedOAuth(oauth)

        try assertDocument(saved, preserves: raw, rotated: oauth)
    }

    func testChangedMissingOrMalformedLoginCannotBeOverwritten() throws {
        for storage in Storage.allCases {
            for replacement in [original.replacingOccurrences(of: "old-refresh", with: "new-login"), "{}", "not-json", nil] {
                let fixture = makeFixture(storage: storage, document: original)
                let generation = fixture.store.credentialGeneration()
                var state = try XCTUnwrap(fixture.store.loadCredentialCandidates().first)
                state.oauth.accessToken = "stale-rotation"
                fixture.setDocument(replacement)

                XCTAssertFalse(try fixture.store.save(state, ifUnchanged: generation))
                XCTAssertEqual(fixture.document, replacement)
            }
        }
    }

    private func concurrentUpdate() throws -> String {
        var object = try json(original)
        object["mcpOAuth"] = ["new-server": ["accessToken": "new-mcp", "enabled": true]]
        object.removeValue(forKey: "futureTopLevel")
        object["newTopLevel"] = ["keep": [false, true]]
        var oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        oauth["futureOAuthField"] = ["newNestedField": ["keep": "latest"]]
        object["claudeAiOauth"] = oauth
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func assertDocument(
        _ saved: String?, preserves original: String, rotated: ClaudeOAuth,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var expected = try json(original)
        var oauth = try XCTUnwrap(expected["claudeAiOauth"] as? [String: Any], file: file, line: line)
        if let access = rotated.accessToken { oauth["accessToken"] = access }
        if let refresh = rotated.refreshToken { oauth["refreshToken"] = refresh }
        if let expiry = rotated.expiresAt { oauth["expiresAt"] = expiry }
        expected["claudeAiOauth"] = oauth
        let actual = try json(XCTUnwrap(saved, file: file, line: line))
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, file: file, line: line)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private enum Storage: CaseIterable {
        case file, accountFile, currentUserKeychain, legacyKeychain
    }

    private struct Fixture {
        let store: ClaudeAuthStore
        let files: FakeFiles
        let keychain: ServiceKeychain
        let storage: Storage
        let path: String
        let service: String

        var document: String? {
            switch storage {
            case .file, .accountFile: files.files[path]
            case .currentUserKeychain: keychain.currentUserValues[service]
            case .legacyKeychain: keychain.values[service]
            }
        }

        func setDocument(_ text: String?) {
            switch storage {
            case .file, .accountFile: files.files[path] = text
            case .currentUserKeychain: keychain.currentUserValues[service] = text
            case .legacyKeychain: keychain.values[service] = text
            }
        }
    }

    private func makeFixture(storage: Storage, document: String) -> Fixture {
        let files = FakeFiles()
        let keychain = ServiceKeychain()
        let swapAccount: ClaudeSwapAccount?
        if storage == .accountFile {
            files.files["/tmp/claude/.claude.json"] =
                #"{"oauthAccount":{"accountUuid":"synthetic-user","organizationUuid":"synthetic-org"}}"#
            swapAccount = ClaudeSwapAccount(root: "/tmp/.claude-swap-backup", slot: "1",
                                            email: "synthetic@example.com",
                                            identityKey: "synthetic-user|synthetic-org",
                                            organizationID: "synthetic-org")
        } else {
            swapAccount = nil
        }
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        let store = ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                                    files: files, keychain: keychain, swapAccount: swapAccount, now: { now })
        let fixture = Fixture(store: store, files: files, keychain: keychain, storage: storage,
                              path: path, service: store.keychainServiceCandidates()[0])
        fixture.setDocument(document)
        return fixture
    }
}
