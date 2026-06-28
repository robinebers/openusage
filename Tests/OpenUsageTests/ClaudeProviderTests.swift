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

    func testPrefersCurrentUserKeychainCredentialsBeforeFile() {
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

        let credentials = store.loadCredentials()

        XCTAssertTrue(hashedService.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(credentials?.oauth.accessToken, "keychain-token")
        XCTAssertEqual(credentials?.oauth.subscriptionType, "max")
    }

    func testPrefersKeychainOverFileEvenWhenFileTokenExpiresLater() {
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

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token"])
        XCTAssertEqual(store.loadCredentials()?.oauth.accessToken, "keychain-token")
    }

    func testEnvironmentTokenIsInferenceOnly() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        let credentials = store.loadCredentials()

        XCTAssertEqual(credentials?.oauth.accessToken, "env-token")
        XCTAssertFalse(store.canFetchLiveUsage(credentials!))
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

    // MARK: - Fingerprint (bugbot #7c1c8948)

    func testCurrentFingerprintExcludesFileMetadataWhenKeychainPreferred() throws {
        // Bugbot-found: when the keychain is the preferred source, the fingerprint must NOT include
        // file metadata — otherwise a touch that only rewrites the file (e.g. `claude --version`
        // updating the file's mtime without rotating the keychain token OpenUsage actually reads)
        // would change the fingerprint and yield a false "rotated" signal, masking the still-expired
        // keychain token and triggering a 5-min CLI cooldown that blocks real recovery.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-fingerprint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credPath = dir.appendingPathComponent(".credentials.json").path
        try #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
            .write(toFile: credPath, atomically: true, encoding: .utf8)

        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": dir.path]),
            files: LocalTextFileAccessor(),
            keychain: keychain,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":4070908800000,"subscriptionType":"max"}}"#

        // Keychain is preferred.
        XCTAssertEqual(store.loadCredentials()?.oauth.accessToken, "keychain-token")

        let before = store.currentFingerprint()

        // Change the file's mtime without touching the keychain.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)],
            ofItemAtPath: credPath
        )

        let after = store.currentFingerprint()

        // The fingerprint must NOT change when only the non-preferred file's metadata changed.
        XCTAssertEqual(before, after,
            "fingerprint must not change when only the non-preferred file source's metadata changes")
    }

    func testCurrentFingerprintIncludesFileMetadataWhenFilePreferred() throws {
        // Complement to the above: when the file IS the preferred source (no keychain), the file
        // metadata IS part of the fingerprint — it's the cheap secondary signal the PR author intended
        // for detecting a file rewrite that the token hash alone might miss.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-fingerprint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credPath = dir.appendingPathComponent(".credentials.json").path
        try #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
            .write(toFile: credPath, atomically: true, encoding: .utf8)

        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": dir.path]),
            files: LocalTextFileAccessor(),
            keychain: FakeKeychain(),  // no keychain → file is preferred
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )

        XCTAssertEqual(store.loadCredentials()?.oauth.accessToken, "file-token")

        let before = store.currentFingerprint()

        // Change the file's mtime without changing its content (so the token hash stays the same).
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)],
            ofItemAtPath: credPath
        )

        let after = store.currentFingerprint()

        // The fingerprint MUST change when the preferred file's mtime changed.
        XCTAssertNotEqual(before, after,
            "fingerprint must change when the preferred file source's metadata changes")
    }
}

final class ClaudeUsageMapperTests: XCTestCase {
    func testMapsUsageWindowsExtraUsageAndPlan() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": { "utilization": 5, "resets_at": "2099-01-01T00:00:00.000Z" },
              "extra_usage": { "is_enabled": true, "used_credits": 500, "monthly_limit": 1000 }
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: "claude_max_subscription_20x")
        )

        XCTAssertEqual(mapped.plan, "Max 20x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Sonnet")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.limit, 10)
    }

    func testUncappedExtraUsageIsAnUnboundedValuesRow() throws {
        // No `monthly_limit`: the spend has no cap, so it's an unbounded `.values` row (which formats
        // through `MetricFormatter`, matching the spend tiles) rather than a baked full-currency `.text`.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"extra_usage":{"is_enabled":true,"used_credits":123456}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        guard case .values(_, let values, _, _)? = mapped.lines.first(where: { $0.label == "Extra usage spent" }) else {
            return XCTFail("Expected an Extra usage spent .values line")
        }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.kind, .dollars)
        XCTAssertEqual(try XCTUnwrap(values.first?.number), 1234.56, accuracy: 0.0001)
        XCTAssertNil(progress(mapped.lines, "Extra usage spent"))
    }

    func testMapsResetsAtFromMicrosecondTimestampWithoutTimezone() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":"2099-06-01T12:00:00.123456"}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(OpenUsageISO8601.string(from: resetsAt), "2099-06-01T12:00:00.123Z")
    }

    func testMapsResetsAtFromUnixEpochNumber() throws {
        let epochSeconds = 2_099_010_100.0
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":2099010100}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, epochSeconds, accuracy: 1)
    }

    func testRateLimitRetryAfterBadge() {
        let mapped = ClaudeUsageMapper.rateLimitedUsage(
            credentials: ClaudeOAuth(subscriptionType: "pro"),
            retryAfterSeconds: 600
        )

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(badge(mapped.lines, "Status"), "Rate limited, retry in ~10m")
        XCTAssertEqual(text(mapped.lines, "Note"), "Live usage rate limited - retry in ~10m")
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }
}

@MainActor
final class ClaudeProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Default-constructed providers wire a failure gate + delegated-refresh coordinator backed by
        // `UserDefaults.standard`. Tests that exercise auth-failure paths would otherwise persist a
        // terminal block / cooldown into the shared standard domain and poison later tests, so clear
        // those keys before each test for a clean slate.
        for key in [
            "claude.refreshGate.state.v1",
            "claude.delegatedRefresh.lastAttemptAt.v1",
            "claude.delegatedRefresh.cooldownSeconds.v1"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testRefreshFetchesLiveUsageAndPassesConfigDirToCcusage() async {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let processRunner = FakeProcessRunner()
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: processRunner,
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertEqual(processRunner.lastCcusageEnvironment?["CLAUDE_CONFIG_DIR"], "/tmp/claude")
        XCTAssertTrue(httpClient.requests.contains { $0.url.absoluteString == "https://api.anthropic.com/api/oauth/usage" })
    }

    func testLiveClaudeUsageReportsResetFields() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_LIVE_CLAUDE"] == "1")

        let store = ClaudeAuthStore()
        guard let state = store.loadCredentials() else {
            throw XCTSkip("No Claude credentials on this machine")
        }

        let response = try await ClaudeUsageClient().fetchUsage(
            accessToken: state.oauth.accessToken ?? "",
            config: store.oauthConfig()
        )
        XCTAssertTrue((200..<300).contains(response.statusCode))
        let resetHeaders = response.headers.filter { $0.key.localizedCaseInsensitiveContains("reset") }
        print("LIVE response reset headers:", resetHeaders)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        for key in ["five_hour", "seven_day", "seven_day_sonnet"] {
            guard let window = body[key] as? [String: Any] else { continue }
            print("LIVE \(key)=", window)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: state.oauth
        )
        for label in ["Session", "Weekly", "Sonnet"] {
            let resetsAt = Self.progress(mapped.lines, label)?.resetsAt
            print("LIVE mapped \(label) resetsAt=", resetsAt as Any)
        }
    }

    func testRetriesOnceAfter401AndPersistsRefreshedCredentials() async {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-token") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"fresh-token","refresh_token":"refresh-2","expires_in":3600}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        let usageCalls = httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
        XCTAssertEqual(usageCalls.count, 2)
        let saved = files.files["/tmp/claude/.credentials.json"] ?? ""
        XCTAssertTrue(saved.contains("fresh-token"))
        XCTAssertTrue(saved.contains("refresh-2"))
    }

    func testFallsBackToFileWhenKeychainTokenIsLockedOut() async {
        // #687: a stale/locked-out token sits in the keychain (its refresh token is server-revoked →
        // invalid_grant → "session expired") while a fresh external `claude` re-login wrote a working
        // token to the file. The refresh must fall through to the file source and recover instead of
        // surfacing the stale keychain error until the app is restarted.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"fresh-access","refreshToken":"fresh-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        // The keychain is always probed first (it's the source of truth), so this exercises the
        // auth-failure fallback: the stale keychain token's refresh is revoked, and recovery comes from
        // falling through to the fresh file token — not from any expiry-based reordering.
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-access") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            // Refresh endpoint: only the stale candidate reaches here, and its refresh token is revoked.
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        // Recovered from the file source: plan + usage reflect the fresh token, with no error badge.
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 42)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testSurfacesAuthErrorWhenAllCredentialSourcesAreExpired() async {
        // The fallback must not mask a genuine all-sources-expired state: when both keychain and file
        // tokens are revoked, the refresh fails loudly with the auth error rather than silently
        // recovering or dropping it.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-stale","refreshToken":"file-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-stale","refreshToken":"keychain-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        // Every usage call 401s and every refresh is revoked → both sources are dead.
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.sessionExpired.localizedDescription)
    }

    func testRateLimitedResponseMapsToRetryBadgeNotError() async {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "600"],
            body: Data()
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
    }

    func testRateLimitServesLastGoodUsageThenBacksOff() async {
        // Tier 2: once a live fetch succeeds, a subsequent 429 keeps showing the cached bars (with a
        // staleness note) instead of a bare badge, and the cooldown then skips the live call entirely so
        // a constantly-limited endpoint isn't hammered. Mirrors the legacy plugin's cache + 429 backoff.
        let t0 = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let clock = TestClock(t0)
        let usageCalls = CallCounter()
        let httpClient = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            }
            if usageCalls.next() == 1 {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { clock.now }
        )

        // 1) Live fetch succeeds and is cached.
        let first = await provider.refresh()
        XCTAssertEqual(Self.progress(first.lines, "Session")?.used, 25)

        // 2) 429: still shows the cached Session bar plus the staleness note, not a bare "Status" badge.
        let second = await provider.refresh()
        XCTAssertEqual(Self.progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))

        // 3) Within the cooldown the live call is skipped entirely; the cached bar is still shown.
        clock.set(t0.addingTimeInterval(60))
        let third = await provider.refresh()
        XCTAssertEqual(Self.progress(third.lines, "Session")?.used, 25)
        XCTAssertEqual(httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }.count, 2)
    }

    func testRefreshSurfacesRequestFailureForNonOAuthRefreshErrorBody() async {
        // The usage call 401s (forcing a refresh); the refresh endpoint then returns a non-OAuth 400
        // (an HTML proxy/WAF page). The snapshot must report a request failure, NOT "token expired" —
        // a transport/infra error the user can't fix by re-logging in.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>Bad Gateway</html>".utf8))
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ProviderUsageErrorText.requestFailed(statusCode: 400))
        XCTAssertNotEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
    }

    // MARK: - Delegated CLI refresh (#753 / #738)

    func testDelegatedRefreshRecoversWhenNoUsableRefreshTokenAndCLISucceeds() async {
        // #753/#738 regression: the only credential source has an expired access token and NO usable
        // refresh token, so an in-process refresh is impossible. Delegating to the `claude` CLI rotates
        // the stored credential (the mock rewrites the file on touch); OpenUsage re-reads it and fetches
        // live usage instead of dead-ending on "token expired".
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            path: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("cli-rotated") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":33,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        // The CLI "touch" rewrites the credentials file with a fresh, unexpired token.
        let runner = FingerprintRotatingRunner {
            files.files[path] = #"{"claudeAiOauth":{"accessToken":"cli-rotated","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: runner,
                environment: FakeEnvironment(["CLAUDE_CLI_PATH": "/fake/claude"]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now },
                sleep: { _ in },
                isExecutable: { $0 == "/fake/claude" },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: ClaudeRefreshFailureGate(
                defaults: Self.isolatedDefaults(),
                storageKey: "gate",
                currentFingerprint: { authStore.currentFingerprint() }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 33)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testDelegatedRefreshRecoversWhenRefreshTokenRevokedAndCLISucceeds() async {
        // Regression for the bugbot-found bug: when the stored refresh token is present but revoked
        // (refresh endpoint returns `invalid_grant`), `fetchLiveUsage` throws `sessionExpired` and the
        // `probe` catch block must STILL get a chance to delegate to the `claude` CLI. The original
        // implementation recorded the terminal failure BEFORE calling `delegatedRefreshIfPossible`, so
        // the gate's 15s recheck throttle (set by `recordTerminalAuthFailure`'s `lastRecheckAt = now`)
        // made `shouldAttempt(now: now)` return false on the immediate next call — the CLI touch never
        // ran and the provider dead-ended on `sessionExpired` even though the CLI could have rotated
        // the credential. Fix: try `delegatedRefreshIfPossible` FIRST; only record the terminal block
        // if delegation also fails.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            // A still-unexpired access token with a USABLE-LOOKING refresh token — the early
            // `needsRefresh && !hasUsableRefreshToken` branch in `fetchLiveUsage` is skipped, so
            // recovery has to come from the `sessionExpired` catch block.
            path: #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"revoked-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("cli-rotated") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":55,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            // Refresh endpoint: the stored refresh token is revoked.
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let runner = FingerprintRotatingRunner {
            files.files[path] = #"{"claudeAiOauth":{"accessToken":"cli-rotated","refreshToken":"fresh-refresh","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: runner,
                environment: FakeEnvironment(["CLAUDE_CLI_PATH": "/fake/claude"]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now },
                sleep: { _ in },
                isExecutable: { $0 == "/fake/claude" },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: ClaudeRefreshFailureGate(
                defaults: Self.isolatedDefaults(),
                storageKey: "gate",
                currentFingerprint: { authStore.currentFingerprint() }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 55)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testDelegatedRefreshFailsWhenCLIUnavailableThenTokenExpired() async {
        // No usable refresh token AND no `claude` CLI to delegate to → the snapshot reports the friendly
        // token-expired error rather than silently recovering.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: FingerprintRotatingRunner {},
                environment: FakeEnvironment([:]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now },
                sleep: { _ in },
                isExecutable: { _ in false }, // no CLI resolves
                defaults: Self.isolatedDefaults()
            ),
            failureGate: ClaudeRefreshFailureGate(
                defaults: Self.isolatedDefaults(), storageKey: "gate",
                currentFingerprint: { authStore.currentFingerprint() }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
    }

    func testTerminalBlockWithUnchangedCredsSkipsNetwork() async {
        // After a terminal failure, while the credential is unchanged the provider must not hit the usage
        // API at all — it short-circuits to token-expired. Exercised by priming the gate as terminal.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let gateDefaults = Self.isolatedDefaults()
        let gate = ClaudeRefreshFailureGate(
            defaults: gateDefaults, storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        // Prime a terminal block (as if a prior refresh hit invalid_grant) more than 15s in the past so
        // the gate's recheck isn't throttled — it rechecks, finds creds unchanged, and stays blocked.
        gate.recordTerminalAuthFailure(reason: "invalid_grant", now: now.addingTimeInterval(-60))

        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: FingerprintRotatingRunner {},
                environment: FakeEnvironment([:]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { _ in false },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
        // The key assertion: no usage API call was made while terminally blocked with unchanged creds.
        XCTAssertTrue(httpClient.requests.isEmpty, "terminal-blocked refresh must not call the usage API")
    }

    // MARK: - 5xx transient failure (bugbot #5afd6cf3)

    func test5xxResponseRecordsTransientFailure() async {
        // Bugbot-found: a 5xx on the usage API should record a transient failure so the
        // delegated-refresh gate backs off (the credential is probably fine, the server is briefly
        // unavailable). The original catch block only recorded transient for `.connectionFailed`, so
        // 5xx (`requestFailed(503)`) skipped the gate entirely.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: FingerprintRotatingRunner {},
                environment: FakeEnvironment([:]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { _ in false },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        _ = await provider.refresh()

        guard case .transient? = gate.currentBlockStatus(now: now) else {
            return XCTFail("expected transient block after 503, got \(String(describing: gate.currentBlockStatus(now: now)))")
        }
    }

    func test4xxNonAuthResponseDoesNotRecordTransientFailure() async {
        // A 4xx that isn't an auth failure (e.g. 404) is NOT transient — it's a real problem that
        // re-trying won't fix. The gate should not record a transient block. (401/403 are treated as
        // auth failures by `ProviderAuthRetry.isAuthFailure` and surface as `tokenExpired`, so they
        // never reach the `ClaudeUsageError` catch block.)
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 404, headers: [:], body: Data()))
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: FingerprintRotatingRunner {},
                environment: FakeEnvironment([:]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { _ in false },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        _ = await provider.refresh()

        XCTAssertNil(gate.currentBlockStatus(now: now),
            "4xx non-auth (404) must not record a transient block")
    }

    // MARK: - Terminal block escape hatch + preferred candidate (bugbot #bc1ed54a, #8898f938)

    func testTerminalBlockAllowsRetryWhenCoordinatorCanAttempt() async {
        // Bugbot #bc1ed54a: a terminal block recorded when the CLI was unavailable (or in cooldown)
        // should NOT block the delegated refresh once the coordinator can attempt again (CLI available
        // and not in cooldown). The short-circuit and delegatedRefreshIfPossible both check
        // coordinator.canAttempt(now:) as an escape hatch, so the CLI gets a chance to rotate the
        // credential even while the terminal block is active.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            path: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("cli-rotated") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":88,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let runner = FingerprintRotatingRunner {
            files.files[path] = #"{"claudeAiOauth":{"accessToken":"cli-rotated","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        }
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        // Prime a terminal block 60s in the past (as if a prior refresh hit invalid_grant when the
        // CLI was unavailable). The fingerprint is the expired token's, which is still current.
        gate.recordTerminalAuthFailure(reason: "sessionExpired", now: now.addingTimeInterval(-60))

        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: runner,
                environment: FakeEnvironment(["CLAUDE_CLI_PATH": "/fake/claude"]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { $0 == "/fake/claude" },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        let snapshot = await provider.refresh()

        // The terminal block is active, but the coordinator can attempt (CLI available, not in
        // cooldown), so the refresh proceeds, the CLI rotates the credential, and live usage is fetched.
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 88)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testTerminalBlockShortCircuitsWhenCoordinatorCannotAttempt() async {
        // Complement to the above: when the coordinator CANNOT attempt (CLI unavailable), the
        // terminal block short-circuits the refresh as before — the escape hatch only opens when the
        // CLI could actually help. This preserves the hammering-prevention behavior for the common
        // case where the CLI isn't installed.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        gate.recordTerminalAuthFailure(reason: "sessionExpired", now: now.addingTimeInterval(-60))

        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: FingerprintRotatingRunner {},
                environment: FakeEnvironment([:]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { _ in false },  // CLI unavailable
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
        XCTAssertTrue(httpClient.requests.isEmpty, "terminal block with CLI unavailable must short-circuit")
    }

    func testDelegatedRefreshUsesPreferredCandidateAfterCLIRotatesKeychain() async {        // Bugbot #8898f938: when the CLI rotates the preferred keychain (which was previously empty)
        // while we're probing the fallback file source, recovery must use the preferred (now-fresh)
        // keychain candidate — not the same-source (still-stale) file candidate. The original code
        // preferred the same source, so auth failed again and recorded a terminal block with the
        // preferred source's (now valid) fingerprint, blocking all future refreshes including the
        // good keychain.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            // File: expired access token, no refresh token — the #738/#753 dead-end shape.
            path: #"{"claudeAiOauth":{"accessToken":"file-expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()  // empty keychain → file is the only candidate initially
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: keychain, now: { now }
        )
        let hashedService = authStore.keychainServiceCandidates().first!

        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("keychain-fresh") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":77,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }

        // The CLI touch writes a fresh token to the KEYCHAIN (the preferred source) — simulating the
        // CLI rotating the keychain while the file is left stale.
        let runner = FingerprintRotatingRunner {
            keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-fresh","refreshToken":"keychain-fresh-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#
        }

        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: runner,
                environment: FakeEnvironment(["CLAUDE_CLI_PATH": "/fake/claude"]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { $0 == "/fake/claude" },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: ClaudeRefreshFailureGate(
                defaults: Self.isolatedDefaults(), storageKey: "gate",
                currentFingerprint: { authStore.currentFingerprint() }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 77)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    // MARK: - Retry fetch gate updates + force recheck (bugbot #88d01254, #f6dcff9f)

    func testRetryFetchAfterDelegatedRefreshRecordsTransientFor5xx() async {
        // Bugbot #88d01254: after a successful delegated CLI recovery, the second `fetchLiveUsage`
        // call sat inside the auth catch handler, so errors from the retry were not handled by the
        // surrounding do/catch — a 5xx on the retry never invoked recordTransientFailure. The fix
        // wraps the retry in its own do/catch that routes through the same gate-update logic.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            path: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                if authorization.contains("expired") {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                // The retry after delegated refresh uses the rotated token; return 503 to exercise
                // the retry-catch path.
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let runner = FingerprintRotatingRunner {
            files.files[path] = #"{"claudeAiOauth":{"accessToken":"cli-rotated","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        }
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: runner,
                environment: FakeEnvironment(["CLAUDE_CLI_PATH": "/fake/claude"]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { $0 == "/fake/claude" },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        _ = await provider.refresh()

        // The retry's 503 must have recorded a transient failure — without the fix, the gate would
        // be empty (the retry's error skipped the catch block).
        guard case .transient? = gate.currentBlockStatus(now: now) else {
            return XCTFail("expected transient block after 503 on retry, got \(String(describing: gate.currentBlockStatus(now: now)))")
        }
    }

    func testTerminalBlockShortCircuitDetectsFreshCredsImmediatelyWithinThrottle() async {
        // Bugbot #f6dcff9f: the terminal short-circuit treated `!shouldAttempt` as "credentials
        // unchanged," but shouldAttempt can be false for up to 15s solely because of the recheck
        // throttle — even after an external re-login changed the fingerprint. So with the CLI
        // unavailable, refresh returned tokenExpired for up to 15s after the user re-logged in,
        // while the already-loaded fresh candidates went untried. The fix force-rechecks the
        // fingerprint in the short-circuit, bypassing the throttle.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            path: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-after-relogin") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":99,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        // Prime a terminal block 5s in the past — INSIDE the 15s recheck throttle, so the throttled
        // shouldAttempt would return false without a fingerprint recheck.
        gate.recordTerminalAuthFailure(reason: "sessionExpired", now: now.addingTimeInterval(-5))

        // Simulate an external `claude` re-login: rewrite the file with a fresh token. The fingerprint
        // changes, but the gate's lastRecheckAt is only 5s ago (within the 15s throttle).
        files.files[path] = #"{"claudeAiOauth":{"accessToken":"fresh-after-relogin","refreshToken":"fresh-refresh","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#

        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: FingerprintRotatingRunner {},
                environment: FakeEnvironment([:]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { _ in false },  // CLI unavailable
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        let snapshot = await provider.refresh()

        // The short-circuit must NOT fire: the fingerprint changed (external re-login), and the
        // force-recheck detects it immediately even within the 15s throttle. The refresh proceeds
        // with the fresh candidate and fetches live usage.
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 99)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testTransientBlockDoesNotBlockCLIRecoveryForAuthFailure() async {
        // Bugbot #737e65d5: while a transient block was active (e.g. after a recent 503), auth
        // failures skipped the CLI entirely and fell through to recording a terminal failure — even
        // though the CLI is the intended recovery path when in-process refresh is impossible. The
        // transient block (from a 5xx on the usage API) is orthogonal to the auth failure; it should
        // not block the CLI for auth recovery. Fix: delegatedRefreshIfPossible tries the CLI
        // whenever the coordinator can attempt, regardless of the gate's block type.
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let path = "/tmp/claude/.credentials.json"
        let files = FakeFiles([
            // Expired access token, no refresh token — the #738/#753 dead-end shape.
            path: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("cli-rotated") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":66,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: FakeKeychain(), now: { now }
        )
        let runner = FingerprintRotatingRunner {
            files.files[path] = #"{"claudeAiOauth":{"accessToken":"cli-rotated","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        }
        let gate = ClaudeRefreshFailureGate(
            defaults: Self.isolatedDefaults(), storageKey: "gate",
            currentFingerprint: { authStore.currentFingerprint() }
        )
        // Prime a TRANSIENT block (as if a prior refresh hit a 503 on the usage API). The block is
        // active for 5 minutes, so shouldAttempt returns false during that window.
        gate.recordTransientFailure(now: now.addingTimeInterval(-60))

        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            ccusageRunner: CcusageRunner(processRunner: FakeProcessRunner(), homeDirectory: { URL(fileURLWithPath: "/Users/test") }),
            coordinator: ClaudeDelegatedRefreshCoordinator(
                processRunner: runner,
                environment: FakeEnvironment(["CLAUDE_CLI_PATH": "/fake/claude"]),
                currentFingerprint: { authStore.currentFingerprint() },
                now: { now }, sleep: { _ in }, isExecutable: { $0 == "/fake/claude" },
                defaults: Self.isolatedDefaults()
            ),
            failureGate: gate,
            now: { now }
        )

        let snapshot = await provider.refresh()

        // The transient block is active, but the CLI is the recovery path for the auth failure. The
        // coordinator can attempt (CLI available, not in cooldown), so the CLI is tried, rotates the
        // credential, and the live fetch succeeds.
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 66)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    private static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "claude.provider.test.\(UUID().uuidString)")!
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private static func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

/// A process runner for the delegated-refresh coordinator: every `--version` touch invokes `onTouch`
/// (a test hook that can rewrite the credentials file to simulate the CLI rotating the token) and
/// returns success. A bare-command probe (no leading `/`) returns failure so CLI resolution falls to
/// the `isExecutable` override the test injects.
private final class FingerprintRotatingRunner: ProcessRunning, @unchecked Sendable {
    private let onTouch: @Sendable () -> Void
    init(_ onTouch: @escaping @Sendable () -> Void) { self.onTouch = onTouch }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        guard executable.hasPrefix("/") else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
        }
        onTouch()
        return ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: "")
    }
}

/// A monotonic call counter for stateful `RoutingHTTPClient` handlers (e.g. "succeed once, then 429").
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// A mutable clock so a test can advance `now` between refreshes to exercise time-based gates.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
