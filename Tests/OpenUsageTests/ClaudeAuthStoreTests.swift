import XCTest
@testable import OpenUsage

final class ClaudeAuthStoreTests: XCTestCase {
    func testParsesHexEncodedCredentials() {
        let raw = #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro"}}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let credentials = ClaudeAuthStore.parseCredentials(hex)

        XCTAssertEqual(credentials?.claudeAiOauth?.accessToken, "token")
        XCTAssertEqual(credentials?.claudeAiOauth?.subscriptionType, "pro")
    }

    func testCredentialDiagnosticsLabelIsTokenFreeWithSourceRefreshAndExpiredFlags() {
        // The info-level "refresh start" / fallback diagnostics must name the source kind and whether each
        // candidate carries a refresh token + is already expired — never any token value (#738 diagnosis).
        let now = Date(timeIntervalSince1970: 1_000_000) // 1_000_000_000 ms

        let fresh = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "ACCESS_SECRET", refreshToken: "REFRESH_SECRET", expiresAt: 2_000_000_000_000),
            source: .keychainCurrentUser(service: "Claude Code-credentials"),
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(fresh.diagnosticsLabel(now: now), "keychainCurrentUser refresh=yes expired=no")
        XCTAssertFalse(fresh.diagnosticsLabel(now: now).contains("SECRET")) // never leaks token values

        // No refresh token + an already-expired access token: the #738 shape that can never self-heal.
        let lockedOut = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: nil, expiresAt: 1),
            source: .file,
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(lockedOut.diagnosticsLabel(now: now), "file refresh=no expired=yes")

        // Empty refresh token counts as absent; missing expiry is reported as unknown, not assumed fresh.
        let unknownExpiry = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: "", expiresAt: nil),
            source: .keychainLegacy(service: "svc"),
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(unknownExpiry.diagnosticsLabel(now: now), "keychainLegacy refresh=no expired=unknown")
    }

    func testPrefersCurrentUserKeychainCredentialsBeforeFile() throws {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max"}}"#

        let credentials = try store.loadCredentialCandidates().first

        XCTAssertTrue(hashedService.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(credentials?.oauth.accessToken, "keychain-token")
        XCTAssertEqual(credentials?.oauth.subscriptionType, "max")
    }

    func testPrefersKeychainOverFileEvenWhenFileTokenExpiresLater() throws {
        // #738 regression: the keychain is Claude Code's live source of truth, so it must win even when a
        // stale `~/.claude/.credentials.json` carries a *later* expiry. Ranking purely by expiry (the old
        // #694 behavior) let that stale file outrank the live keychain and starved token refresh. Both
        // candidates stay available so the refresh loop can still fall back keychain → file on auth expiry.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":4070908800000,"subscriptionType":"max"}}"#

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token"])
        XCTAssertEqual(try store.loadCredentialCandidates().first?.oauth.accessToken, "keychain-token")
    }

    func testEnvironmentTokenIsInferenceOnly() throws {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        let credentials = try store.loadCredentialCandidates().first

        XCTAssertEqual(credentials?.oauth.accessToken, "env-token")
        XCTAssertEqual(store.liveUsageAvailability(credentials!), .inferenceOnlyToken)
    }

    func testEnvTokenDoesNotShadowProfileScopedStoredLogin() throws {
        // An inference-only CLAUDE_CODE_OAUTH_TOKEN (often just ambiently exported and captured from the
        // login shell) must not shadow a real stored login that CAN read usage. The profile-scoped login
        // is preferred for the live usage call; the env token trails as an inference-only fallback.
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "env-token"])
        // The keychain login (first) can fetch live usage; the env token is the inference-only fallback.
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .available)
        XCTAssertFalse(candidates[0].inferenceOnly)
        XCTAssertEqual(store.liveUsageAvailability(candidates[1]), .inferenceOnlyToken)
    }

    func testEnvTokenIsSoleCandidateWhenStoredLoginCannotReadUsage() throws {
        // A stored login that itself lacks user:profile can't read usage either, so it is not preferred
        // over the env token; the env token stays the sole inference-only candidate (spend tiles still
        // load) — the headless/no-usable-login behavior is unchanged.
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"inference-login","subscriptionType":"max","scopes":["user:inference"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["env-token"])
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .inferenceOnlyToken)
    }

    func testEnvFallbackBorrowsMetadataFromThePreferredLiveCapableLogin() throws {
        // When the first stored login is NOT live-capable but a later one is (an inference-only keychain
        // login plus a profile-scoped file login), the env fallback should inherit its display metadata
        // from the credential actually preferred (the file login), not from the keychain login we skipped.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: files,
            keychain: keychain
        )
        keychain.currentUserValues[store.keychainServiceCandidates().first!] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"pro","scopes":["user:inference"]}}"#

        let candidates = try store.loadCredentialCandidates()

        // Keychain login (no user:profile) is dropped from the usage-capable set; the file login is
        // preferred and the env token trails.
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["file-token", "env-token"])
        // The env fallback borrows the preferred (file) login's plan, not the skipped keychain login's.
        XCTAssertEqual(candidates[1].oauth.subscriptionType, "max")
    }

    func testLiveUsageAvailabilityReflectsProfileScope() {
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain())
        func state(_ scopes: [String]?, inferenceOnly: Bool = false) -> ClaudeCredentialState {
            ClaudeCredentialState(
                oauth: ClaudeOAuth(accessToken: "token", scopes: scopes),
                source: .keychainCurrentUser(service: "Claude Code-credentials"),
                fullData: nil,
                inferenceOnly: inferenceOnly
            )
        }

        // Older credentials predate the scopes field; an absent/empty list is "unknown, allow".
        XCTAssertEqual(store.liveUsageAvailability(state(nil)), .available)
        XCTAssertEqual(store.liveUsageAvailability(state([])), .available)
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference", "user:profile"])), .available)
        // An inference-only token (e.g. from `claude setup-token`) lacks user:profile → can't read usage.
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"])), .missingProfileScope)
        // An explicit env token is inference-only by design: silent, not a missing-scope notice.
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"], inferenceOnly: true)), .inferenceOnlyToken)
    }

    func testMalformedCustomOAuthURLThrowsInsteadOfCrashing() {
        // A malformed custom OAuth URL is system-boundary input: oauthConfig() must fail loudly
        // rather than force-unwrap a nil URL (which crashes) or silently fall back to prod.
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_CUSTOM_OAUTH_URL": "http://exa mple.com"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        XCTAssertThrowsError(try store.oauthConfig()) { error in
            guard case ClaudeAuthError.invalidOAuthURL = error else {
                return XCTFail("expected ClaudeAuthError.invalidOAuthURL, got \(error)")
            }
        }

        // The forgiving credential-load path only needs the file suffix, so a malformed URL must not
        // break keychain candidate resolution.
        XCTAssertEqual(store.keychainServiceCandidates(), ["Claude Code-custom-oauth-credentials"])
    }
}
