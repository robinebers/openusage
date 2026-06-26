import XCTest
@testable import OpenUsage

final class AntigravityProviderTests: XCTestCase {

    // MARK: - Helpers

    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = line else { return nil }
        return used
    }

    private func resetsAt(_ line: MetricLine?) -> Date? {
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = line else { return nil }
        return resetsAt
    }

    // MARK: - Mapper: pooling

    func testBuildLinesPoolsAndOrders() {
        let configs = [
            AntigravityModelConfig(label: "Gemini 3 Pro (High)", modelID: "a", remainingFraction: 0.8, resetTime: nil),
            AntigravityModelConfig(label: "Gemini 3 Pro (Low)", modelID: "b", remainingFraction: 0.5, resetTime: nil),
            AntigravityModelConfig(label: "Gemini 3.5 Flash (Medium)", modelID: "c", remainingFraction: 1.0, resetTime: nil),
            AntigravityModelConfig(label: "Claude Sonnet 4.6 (Thinking)", modelID: "d", remainingFraction: 0.3, resetTime: nil),
            AntigravityModelConfig(label: "GPT-OSS 120B (Medium)", modelID: "e", remainingFraction: 0.9, resetTime: nil)
        ]
        let lines = AntigravityUsageMapper.buildLines(configs)

        XCTAssertEqual(lines.map(\.label), ["Gemini Pro", "Gemini Flash", "Claude"])
        XCTAssertEqual(used(lines[0]), 50)  // worst Gemini Pro fraction (0.5) -> 50% used
        XCTAssertEqual(used(lines[1]), 0)   // Flash full
        XCTAssertEqual(used(lines[2]), 70)  // worst non-Gemini (Claude 0.3) -> 70% used
    }

    func testBuildLinesDedupKeepsWorstFractionAndItsReset() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let configs = [
            AntigravityModelConfig(label: "Gemini 3 Pro (High)", modelID: "a", remainingFraction: 0.9, resetTime: later),
            AntigravityModelConfig(label: "Gemini 3 Pro (Low)", modelID: "b", remainingFraction: 0.2, resetTime: earlier)
        ]
        let lines = AntigravityUsageMapper.buildLines(configs)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(used(lines[0]), 80)              // worst fraction 0.2
        XCTAssertEqual(resetsAt(lines[0]), earlier)     // reset of the kept (worst) entry
    }

    func testBuildLinesDropsBlacklistedAndEmptyLabels() {
        let configs = [
            AntigravityModelConfig(label: "Gemini 2.5 Pro", modelID: "MODEL_GOOGLE_GEMINI_2_5_PRO", remainingFraction: 1, resetTime: nil),
            AntigravityModelConfig(label: "   ", modelID: "x", remainingFraction: 1, resetTime: nil),
            AntigravityModelConfig(label: "Gemini 3.1 Pro (High)", modelID: "ok", remainingFraction: 0.6, resetTime: nil)
        ]
        let lines = AntigravityUsageMapper.buildLines(configs)
        XCTAssertEqual(lines.map(\.label), ["Gemini Pro"])
        XCTAssertEqual(used(lines[0]), 40)
    }

    func testBuildLinesClampsOutOfRangeFractions() {
        let configs = [
            AntigravityModelConfig(label: "Gemini 3 Pro", modelID: "a", remainingFraction: 1.5, resetTime: nil),
            AntigravityModelConfig(label: "Claude Opus", modelID: "b", remainingFraction: -0.2, resetTime: nil)
        ]
        let lines = AntigravityUsageMapper.buildLines(configs)
        XCTAssertEqual(used(lines.first { $0.label == "Gemini Pro" }), 0)   // clamped to full
        XCTAssertEqual(used(lines.first { $0.label == "Claude" }), 100)     // clamped to empty
    }

    func testPoolLabelClassification() {
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("Gemini 3.1 Pro"), "Gemini Pro")
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("Gemini 3.5 Flash"), "Gemini Flash")
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("Gemini 3.1 Flash Lite"), "Gemini Flash")
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("Claude Opus 4.6"), "Claude")
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("GPT-OSS 120B"), "Claude")
        // A Gemini model that is neither Pro nor Flash must stay in a Gemini pool, never Claude.
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("Gemini Ultra"), "Gemini Pro")
        XCTAssertEqual(AntigravityUsageMapper.poolLabel("gemini-3"), "Gemini Pro")
    }

    func testNormalizeLabelStripsTrailingParenthetical() {
        XCTAssertEqual(AntigravityUsageMapper.normalizeLabel("Gemini 3 Pro (High)"), "Gemini 3 Pro")
        XCTAssertEqual(AntigravityUsageMapper.normalizeLabel("Claude Sonnet 4.6"), "Claude Sonnet 4.6")
    }

    // MARK: - Mapper: plan normalization

    func testFormatPlan() {
        XCTAssertEqual(AntigravityUsageMapper.formatPlan("Google AI Pro"), "Pro")
        XCTAssertEqual(AntigravityUsageMapper.formatPlan("Google AI Ultra"), "Ultra")
        XCTAssertEqual(AntigravityUsageMapper.formatPlan("Gemini Code Assist in Google One AI Pro"), "Pro")
        XCTAssertEqual(AntigravityUsageMapper.formatPlan("Gemini Code Assist"), "Gemini Code Assist")
        XCTAssertNil(AntigravityUsageMapper.formatPlan("   "))
        XCTAssertNil(AntigravityUsageMapper.formatPlan(nil))
    }

    // MARK: - Mapper: response parsing

    func testParseUserStatusPrefersUserTier() {
        let json = """
        {"userStatus":{"userTier":{"name":"Google AI Pro"},
        "planStatus":{"planInfo":{"planName":"Pro"}},
        "cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 3.1 Pro (High)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M16"},
           "quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-06-26T09:37:05Z"}},
          {"label":"Claude Sonnet 4.6 (Thinking)","modelOrAlias":{"model":"MODEL_PLACEHOLDER_M35"},
           "quotaInfo":{"remainingFraction":1,"resetTime":"2026-06-26T09:47:54Z"}}
        ]}}}
        """
        let parsed = AntigravityUsageMapper.parseUserStatus(Data(json.utf8))
        XCTAssertEqual(parsed?.plan, "Pro")
        let lines = AntigravityUsageMapper.buildLines(parsed?.configs ?? [])
        XCTAssertEqual(lines.map(\.label), ["Gemini Pro", "Claude"])
        XCTAssertEqual(used(lines[0]), 50)
        XCTAssertEqual(used(lines[1]), 0)
        XCTAssertNotNil(resetsAt(lines[0]))
    }

    func testParseUserStatusReturnsNilWithoutUserStatus() {
        XCTAssertNil(AntigravityUsageMapper.parseUserStatus(Data("{}".utf8)))
    }

    func testParseCloudCodeModelsDropsInternalAndEmptyLabel() {
        let json = """
        {"models":{
          "a":{"model":"MODEL_OK","displayName":"Gemini 3.1 Pro (High)","quotaInfo":{"remainingFraction":1}},
          "b":{"model":"MODEL_CHAT_23310","displayName":"chat_23310","isInternal":true,"quotaInfo":{"remainingFraction":1}},
          "c":{"model":"MODEL_GOOGLE_GEMINI_2_5_PRO","displayName":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":1}},
          "d":{"model":"MODEL_EMPTY","displayName":"","quotaInfo":{"remainingFraction":1}}
        }}
        """
        let configs = AntigravityUsageMapper.parseCloudCodeModels(Data(json.utf8))
        // isInternal (b) and empty-displayName (d) dropped at parse; blacklist (c) survives to buildLines.
        XCTAssertEqual(configs.count, 2)
        let lines = AntigravityUsageMapper.buildLines(configs)
        XCTAssertEqual(lines.map(\.label), ["Gemini Pro"])  // c filtered by blacklist
    }

    func testParseCloudCodeModelsTreatsMissingQuotaAsDepleted() {
        let json = """
        {"models":{"a":{"model":"MODEL_OK","displayName":"Gemini 3.1 Pro (High)"}}}
        """
        let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseCloudCodeModels(Data(json.utf8)))
        XCTAssertEqual(used(lines.first), 100)  // no quotaInfo -> fully used
    }

    func testParseLoadCodeAssistPlan() {
        let json = """
        {"currentTier":{"name":"Gemini Code Assist"},"paidTier":{"name":"Gemini Code Assist in Google One AI Pro"}}
        """
        XCTAssertEqual(AntigravityUsageMapper.parseLoadCodeAssistPlan(Data(json.utf8)), "Pro")
    }

    func testParseQuotaBuckets() {
        let json = """
        {"buckets":[{"modelId":"gemini-3-pro-preview","remainingFraction":0.5,"resetTime":"2026-06-27T04:44:01Z"},
                    {"modelId":"gemini-3-flash-preview","remainingFraction":1}]}
        """
        let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseQuotaBuckets(Data(json.utf8)))
        XCTAssertEqual(lines.map(\.label), ["Gemini Pro", "Gemini Flash"])
        XCTAssertEqual(used(lines[0]), 50)
    }

    // MARK: - Language server discovery (pure parsing)

    func testExtractFlagBothForms() {
        let command = "/bin/language_server --csrf_token ABC-123 --extension_server_port=42 --foo"
        XCTAssertEqual(LanguageServerDiscovery.extractFlag(command: command, flag: "--csrf_token"), "ABC-123")
        XCTAssertEqual(LanguageServerDiscovery.extractFlag(command: command, flag: "--extension_server_port"), "42")
        XCTAssertNil(LanguageServerDiscovery.extractFlag(command: command, flag: "--missing"))
    }

    func testParseListeningPorts() {
        let lsof = """
        COMMAND    PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        language_ 4276 rebers    6u  IPv4 0xb01a07fcc634a8e1      0t0  TCP 127.0.0.1:52168 (LISTEN)
        language_ 4276 rebers    7u  IPv4 0x7eb2d525b7317601      0t0  TCP 127.0.0.1:52169 (LISTEN)
        """
        XCTAssertEqual(LanguageServerDiscovery.parseListeningPorts(lsof), [52168, 52169])
    }

    func testMarkerRankExactFlagBeatsPathSubstring() {
        let withFlag = "/x/language_server --app_data_dir antigravity --csrf_token z"
        XCTAssertEqual(LanguageServerDiscovery.markerRank(command: withFlag, markersLower: ["antigravity"]), 0)

        let pathOnly = "/opt/antigravity/bin/language_server --standalone"
        XCTAssertEqual(LanguageServerDiscovery.markerRank(command: pathOnly, markersLower: ["antigravity"]), 1)

        let mismatch = "/x/language_server --app_data_dir windsurf"
        XCTAssertNil(LanguageServerDiscovery.markerRank(command: mismatch, markersLower: ["antigravity"]))

        XCTAssertEqual(LanguageServerDiscovery.markerRank(command: "anything", markersLower: []), 0)
    }

    func testCommandMatchesProcess() {
        let ls = "/Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone"
        XCTAssertTrue(LanguageServerDiscovery.commandMatchesProcess(command: ls, processNameLower: "language_server"))
        let agy = "/Users/x/.local/bin/agy"
        XCTAssertTrue(LanguageServerDiscovery.commandMatchesProcess(command: agy, processNameLower: "agy"))
        XCTAssertFalse(LanguageServerDiscovery.commandMatchesProcess(command: ls, processNameLower: "agy"))
    }

    func testRankedCandidatesFindsLanguageServer() {
        let ps = """
        4221 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        4276 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --csrf_token tok --app_data_dir antigravity
        4278 /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper (Renderer).app/Contents/MacOS/Antigravity Helper (Renderer) --type=renderer
        """
        let options = LanguageServerDiscovery.Options(
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port"
        )
        let candidates = LanguageServerDiscovery.rankedCandidates(psOutput: ps, options: options)
        XCTAssertEqual(candidates.map(\.pid), [4276])
    }

    // MARK: - Keychain token extraction

    func testExtractTokenFromGoKeyringWrappedJSON() {
        let inner = """
        {"token":{"access_token":"ya29.test","refresh_token":"1//refresh","expiry":"2099-01-01T00:00:00Z","token_type":"Bearer"},"auth_method":"consumer"}
        """
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let token = AntigravityAuthStore.extractToken(fromKeychainRaw: wrapped)
        XCTAssertEqual(token?.accessToken, "ya29.test")
        XCTAssertEqual(token?.refreshToken, "1//refresh")
        XCTAssertEqual(token?.expiry, OpenUsageISO8601.date(from: "2099-01-01T00:00:00Z"))
    }

    func testExtractTokenFromRawJSONAndBearerAndPlain() {
        let plainJSON = #"{"access_token":"abc","refresh_token":"r"}"#
        XCTAssertEqual(AntigravityAuthStore.extractToken(fromKeychainRaw: plainJSON)?.accessToken, "abc")
        XCTAssertEqual(AntigravityAuthStore.extractToken(fromKeychainRaw: "Bearer xyz")?.accessToken, "xyz")
        XCTAssertEqual(AntigravityAuthStore.extractToken(fromKeychainRaw: "rawtoken")?.accessToken, "rawtoken")
    }

    func testLoadCachedTokenAppliesRefreshBuffer() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func store(expiresInSeconds: Double) -> AntigravityAuthStore {
            let ms = (now.timeIntervalSince1970 + expiresInSeconds) * 1000
            let files = FakeFiles([AntigravityAuthStore.cachePath: #"{"accessToken":"ya29.cached","expiresAtMs":\#(ms)}"#])
            return AntigravityAuthStore(keychain: FakeKeychain(nil), files: files, now: { now })
        }
        // Within the 60s refresh buffer -> treated as expired (avoids a near-certain 401 + extra refresh).
        XCTAssertNil(store(expiresInSeconds: 30).loadCachedToken())
        XCTAssertEqual(store(expiresInSeconds: 7200).loadCachedToken(), "ya29.cached")
    }

    func testLoadKeychainTokenThroughStore() {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let store = AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles())
        let token = store.loadKeychainToken()
        XCTAssertEqual(token?.accessToken, "ya29.kc")
        XCTAssertEqual(token?.refreshToken, "1//r")
    }

    // MARK: - Provider integration (Cloud Code path, no language server)

    @MainActor
    func testRefreshUsesCloudCodeWhenNoLanguageServer() async {
        let modelsJSON = """
        {"models":{
          "p":{"model":"MODEL_P","displayName":"Gemini 3.1 Pro (High)","quotaInfo":{"remainingFraction":0.4,"resetTime":"2026-06-26T09:37:05Z"}},
          "f":{"model":"MODEL_F","displayName":"Gemini 3.5 Flash (Low)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-06-26T09:37:05Z"}},
          "c":{"model":"MODEL_C","displayName":"Claude Opus 4.6 (Thinking)","quotaInfo":{"remainingFraction":0.7,"resetTime":"2026-06-26T09:44:00Z"}}
        }}
        """
        let planJSON = #"{"paidTier":{"name":"Google AI Pro"}}"#

        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.contains("fetchAvailableModels") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(modelsJSON.utf8))
            }
            if path.contains("loadCodeAssist") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(planJSON.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()

        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Gemini Pro", "Gemini Flash", "Claude"])
        XCTAssertEqual(used(snapshot.lines[0]), 60)
        XCTAssertEqual(used(snapshot.lines[1]), 0)
        XCTAssertEqual(used(snapshot.lines[2]), 30)
    }

    @MainActor
    func testRefreshErrorsWhenNothingAvailable() async {
        let routing = RoutingHTTPClient { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    @MainActor
    func testRefreshReportsUnavailableWhenSignedInButCloudCodeDown() async {
        // Valid keychain token, but every Cloud Code endpoint is down. A signed-in user should see a
        // transient failure (.network), not "not signed in" (.notLoggedIn).
        let routing = RoutingHTTPClient { _ in HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    @MainActor
    func testDeadRefreshTokenReportsAuthExpired() async {
        // Access token already expired (skipped); refresh returns 400 invalid_grant. A dead refresh
        // token is expired auth (.authExpired), not a transient outage.
        let routing = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let inner = #"{"token":{"access_token":"ya29.old","refresh_token":"1//dead","expiry":"2000-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    @MainActor
    func testAuthFailureThenThrottledRefreshReportsUnavailable() async {
        // A usable token 401s (sawAuthFailure), then the OAuth refresh hits 503. An expired access token
        // is normal and the refresh token may be fine, so this is a transient outage (.network), not
        // authExpired.
        let routing = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    @MainActor
    func testRateLimitedRefreshReportsUnavailable() async {
        // Access token expired; refresh hits 429 (rate limited). Transient, not a revoked token — so
        // .network, not .authExpired.
        let routing = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(statusCode: 429, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let inner = #"{"token":{"access_token":"ya29.old","refresh_token":"1//r","expiry":"2000-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    @MainActor
    func testRefreshAfterSuccessfulRefreshTreatsOutageAsUnavailable() async {
        // First fetch 401 -> OAuth refresh succeeds -> retry fetch 503. The refreshed token is valid, so
        // this is a transient outage (.network), not authExpired.
        let fetchCount = Counter()
        let routing = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: Data(#"{"access_token":"ya29.new","expires_in":3600}"#.utf8))
            }
            if request.url.path.contains("fetchAvailableModels") {
                return HTTPResponse(statusCode: fetchCount.next() == 0 ? 401 : 503, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner())
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }
}

/// Returns empty output for every subprocess — makes language-server discovery find nothing, so a
/// provider test exercises the Cloud Code path deterministically.
private struct EmptyProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// Serial call counter for routing handlers that must vary their response across requests.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}
