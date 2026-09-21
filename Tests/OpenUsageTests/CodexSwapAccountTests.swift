import XCTest
@testable import OpenUsage

@MainActor
final class CodexSwapAccountTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/test")
    private let environment = FakeEnvironment(["CODEX_HOME": "/test/main"])
    private let a = CodexAccountIdentity(accountID: "workspace-a", email: "personal@example.com")!
    private let b = CodexAccountIdentity(accountID: "workspace-b", email: "work@example.com")!

    private func defaults() throws -> UserDefaults {
        let suite = "CodexSwap.\(UUID().uuidString)"
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    nonisolated static func credential(_ identity: CodexAccountIdentity, token: String) -> String {
        let claims = #"{"email":"\#(identity.email ?? "")","https://api.openai.com/auth":{"chatgpt_account_id":"\#(identity.accountID)"}}"#
        let id = "header." + Data(claims.utf8).base64EncodedString() + ".signature"
        return #"{"tokens":{"access_token":"\#(token)","refresh_token":"never-refresh-\#(token)","id_token":"\#(id)","account_id":"\#(identity.accountID)"},"last_refresh":"2000-01-01T00:00:00Z"}"#
    }

    private func fixture(second: CodexAccountIdentity? = nil) -> FakeFiles {
        let second = second ?? b
        let registry = #"""
        {"schemaVersion":1,"mainHome":"/test/main","default":2,"accounts":[
          {"number":1,"alias":"Personal","home":"/test/personal","managed":true,"shareHistory":true,
           "identity":{"accountId":"\#(a.accountID)","email":"\#(a.email!)","plan":"pro"}},
          {"number":2,"alias":"Work","home":"/test/work","managed":true,"enabled":false,"shareHistory":true,
           "identity":{"accountId":"\#(second.accountID)","email":"\#(second.email!)","plan":"team"}}
        ],"futureField":true}
        """#
        return FakeFiles([
            "/test/.local/share/codex-swap/accounts.json": registry,
            "/test/main/auth.json": Self.credential(a, token: "main-a"),
            "/test/personal/auth.json": Self.credential(a, token: "saved-a"),
            "/test/work/auth.json": Self.credential(second, token: "saved-b")
        ])
    }

    private func assembly(_ files: FakeFiles, store: ProviderAccountsStore) async -> ProviderAccountAssembly {
        let home = home
        return await ProviderAccountAssembly.make(observer: DefaultAccountObserver(
            environment: environment, files: files, keychain: FakeKeychain(), homeDirectory: { home }
        ), accountsStore: store, families: ["codex"])
    }

    func testDiscoveryMergesOverlapAndKeepsIDsLayoutPinsAcrossDefaultSwitches() async throws {
        let files = fixture()
        let defaults = try defaults()
        let store = ProviderAccountsStore(defaults: defaults)
        // Upgrade an existing single-account install without moving its card or pins.
        store.reconcile(with: [.init(family: "codex", identityKey: a.accountID, label: a.email,
                                    sources: [.init(kind: .defaultHome, anchor: "/test/main", holdsDefaultSource: true)])])
        let initial = await assembly(files, store: store)
        XCTAssertEqual(initial.codexCards.count, 2)
        XCTAssertEqual(initial.codexCards.first { $0.identity == a }?.id, "codex")
        let ids = Dictionary(uniqueKeysWithValues: initial.codexCards.map { ($0.identity.key, $0.id) })
        let registry = WidgetRegistry.from(ProviderCatalog.make(defaults: defaults, codexCards: initial.codexCards))
        let layout = LayoutStore(registry: registry, defaults: defaults)
        layout.setPinned(true, for: ids[b.key]! + ".weekly")
        _ = layout.reorderProvider(dragged: ids[b.key]!, target: ids[a.key]!)
        let pins = layout.pinnedMetricIDs
        let order = layout.providerOrder
        for selected in [b, a, b] {
            files.files["/test/main/auth.json"] = Self.credential(selected, token: "new-default")
            let next = await assembly(files, store: store)
            XCTAssertEqual(next.codexCards.count, 2)
            XCTAssertEqual(next.codexCards.map(\.id), initial.codexCards.map(\.id))
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: next.codexCards.map { ($0.identity.key, $0.id) }), ids)
            let repeated = await assembly(files, store: store)
            XCTAssertEqual(repeated.codexCards, next.codexCards)
            XCTAssertTrue(next.codexCards.allSatisfy { !$0.allowsUnattributedHistory })
            let restored = LayoutStore(registry: .from(ProviderCatalog.make(codexCards: next.codexCards)), defaults: defaults)
            XCTAssertEqual(restored.pinnedMetricIDs, pins)
            XCTAssertEqual(restored.providerOrder, order)
            XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.identityKey, selected.key)
        }
    }

    func testSameEmailDifferentWorkspacesAndSameWorkspaceDifferentUsersStaySeparate() async throws {
        for second in [CodexAccountIdentity(accountID: "workspace-b", email: a.email)!,
                       CodexAccountIdentity(accountID: a.accountID, email: b.email)!] {
            let cards = await assembly(fixture(second: second), store: ProviderAccountsStore(defaults: try defaults())).codexCards
            XCTAssertEqual(cards.count, 2)
            XCTAssertEqual(Set(cards.map(\.displayName)).count, 2)
            XCTAssertEqual(Set(cards.map { $0.identity.key }).count, 2)
        }
    }

    func testAdditionalCardInheritsDefaultsOnFreshAndExistingLayouts() async throws {
        let defaults = try defaults()
        let cards = await assembly(fixture(), store: ProviderAccountsStore(defaults: defaults)).codexCards
        let registry = WidgetRegistry.from(ProviderCatalog.make(codexCards: cards))
        let ids = cards.map(\.id)
        func layout() -> LayoutStore {
            LayoutStore(registry: registry, defaults: defaults,
                defaultMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.metricIDs, providerIDs: ids),
                defaultPinnedMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.pinnedMetricIDs, providerIDs: ids),
                defaultExpandedMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.expandedMetricIDs, providerIDs: ids))
        }
        let fresh = layout()
        XCTAssertTrue(Set(ids).isSubset(of: Set(fresh.displayGroups.map { $0.provider.id })))
        for id in ids {
            XCTAssertTrue(fresh.pinnedMetricIDs.contains(id + ".weekly"))
            XCTAssertTrue(fresh.expandedMetricIDs.contains(id + ".spark"))
        }
        // Model the pre-Swap installation, including an explicit pin customization.
        for hasSavedPlacement in [false, true] {
            let existingDefaults = try self.defaults()
            let legacy = LayoutStore(registry: registry, defaults: existingDefaults)
            if hasSavedPlacement {
                LayoutPersistence(defaults: existingDefaults, storageKey: "openusage.layout.v1").savePlaced(legacy.placed)
            }
            legacy.setPinned(false, for: "codex.session")
            let oldPins = legacy.pinnedMetricIDs
            let upgraded = LayoutStore(registry: registry, defaults: existingDefaults,
                defaultMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.metricIDs, providerIDs: ids),
                defaultPinnedMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.pinnedMetricIDs, providerIDs: ids),
                defaultExpandedMetricIDs: DefaultLayout.expandingAccounts(DefaultLayout.expandedMetricIDs, providerIDs: ids))
            XCTAssertTrue(Set(ids).isSubset(of: Set(upgraded.displayGroups.map { $0.provider.id })))
            XCTAssertEqual(upgraded.pinnedMetricIDs, oldPins)
            XCTAssertTrue(upgraded.expandedMetricIDs.contains(try XCTUnwrap(ids.first { $0 != "codex" }) + ".spark"))
        }
    }

    func testRegistryOverridesVersionAndMalformedEntries() {
        let files = fixture()
        let registry = files.files["/test/.local/share/codex-swap/accounts.json"]!
        for (environment, path) in [
            (FakeEnvironment(["XSWAP_HOME": "/custom"]), "/custom/accounts.json"),
            (FakeEnvironment(["XSWAP_HOME": "~/custom"]), "/test/custom/accounts.json"),
            (FakeEnvironment(["XDG_DATA_HOME": "/data"]), "/data/codex-swap/accounts.json"),
            (FakeEnvironment(["XDG_DATA_HOME": "relative"]), "/test/.local/share/codex-swap/accounts.json")
        ] {
            let sources = FakeFiles([path: registry])
            XCTAssertEqual(CodexSwapAccount.discover(environment: environment, files: sources, home: home).count, 2)
            sources.files[path] = registry.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":9")
            XCTAssertTrue(CodexSwapAccount.discover(environment: environment, files: sources, home: home).isEmpty)
            sources.files[path] = "malformed"
            XCTAssertTrue(CodexSwapAccount.discover(environment: environment, files: sources, home: home).isEmpty)
        }
    }

    private func auth(_ identity: CodexAccountIdentity, files: FakeFiles, keychain: FakeKeychain) -> CodexAuthStore {
        CodexAuthStore(environment: environment, files: files, keychain: keychain,
                       expectedIdentity: identity, additionalAuthHomes: ["/test/personal", "/test/work"])
    }

    private func provider(_ auth: CodexAuthStore, http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(authStore: auth, usageClient: CodexUsageClient(http: http),
                      logUsageScanner: CodexLogUsageScanner(allowsUnattributedHistory: false),
                      allowsUnattributedHistory: false, pricing: { TestPricing.bundled })
    }

    nonisolated private static func response(_ used: Int, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(
            #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":\#(used),"limit_window_seconds":18000}}}"#.utf8))
    }

    func testFallbackBothDirectionsRejectsOtherAccountAndNeverRotatesOrWrites() async throws {
        for identity in [a, b] {
            for keychainFallback in [false, true] {
                for rejectionStatus in [401, 403] {
                    let files = fixture()
                    let keychain = FakeKeychain(Self.credential(keychainFallback ? identity : (identity == a ? b : a), token: "keychain"))
                    files.files["/test/main/auth.json"] = Self.credential(identity, token: "rejected")
                    let store = auth(identity, files: files, keychain: keychain)
                    let originalFiles = files.files
                    let originalKeychain = keychain.value
                    let http = RoutingHTTPClient { request in
                        XCTAssertEqual(request.method, "GET")
                        XCTAssertEqual(request.headers["ChatGPT-Account-Id"], identity.accountID)
                        let token = request.headers["Authorization"]!
                        XCTAssertNotEqual(token, identity.email == "personal@example.com" ? "Bearer saved-b" : "Bearer saved-a")
                        let rejected = token == "Bearer rejected" || (keychainFallback && token != "Bearer keychain")
                        return Self.response(37, status: rejected ? rejectionStatus : 200)
                    }
                    let candidate = provider(store, http: http)
                    let hasCredentials = await candidate.hasLocalCredentials()
                    XCTAssertTrue(hasCredentials)
                    let snapshot = await candidate.refresh()
                    XCTAssertNil(snapshot.errorCategory)
                    guard case .progress(_, let used, _, _, _, _, _, _) = snapshot.line(label: "Session") else {
                        return XCTFail("Missing limits")
                    }
                    XCTAssertEqual(used, 37)
                    XCTAssertEqual(files.files, originalFiles)
                    XCTAssertEqual(keychain.value, originalKeychain)
                    XCTAssertTrue(store.loadAuthCandidates().allSatisfy { $0.auth.tokens?.refreshToken == nil && $0.readOnly })
                    XCTAssertThrowsError(try store.save(XCTUnwrap(store.loadAuthCandidates().first)))
                    XCTAssertTrue(snapshot.usageHistory?.series.daily.isEmpty == true)
                }
            }
        }
    }

    func testStaleResponsesCannotOverwriteReplacedCredentialsOrFollowOtherIdentity() async throws {
        for identity in [a, b] {
            for changedHome in ["/test/main", identity == a ? "/test/personal" : "/test/work"] {
                for replaceWithOtherIdentity in [false, true] {
                    let files = fixture()
                    let other = identity == a ? b : a
                    let changedPath = changedHome + "/auth.json"
                    files.files["/test/main/auth.json"] = Self.credential(other, token: "other-default")
                    files.files[changedPath] = Self.credential(identity, token: "stale")
                    let keychain = FakeKeychain(Self.credential(identity, token: "matching-keychain"))
                    let replacement = Self.credential(replaceWithOtherIdentity ? other : identity, token: "replacement")
                    let http = RoutingHTTPClient { request in
                        XCTAssertEqual(request.headers["ChatGPT-Account-Id"], identity.accountID)
                        let stale = request.headers["Authorization"] == "Bearer stale"
                        if stale { files.files[changedPath] = replacement }
                        if replaceWithOtherIdentity { XCTAssertNotEqual(request.headers["Authorization"], "Bearer replacement") }
                        return Self.response(stale ? 99 : 24)
                    }
                    let result = await provider(auth(identity, files: files, keychain: keychain), http: http).refresh()
                    guard case .progress(_, let used, _, _, _, _, _, _) = result.line(label: "Session") else {
                        return XCTFail("Missing current limits")
                    }
                    XCTAssertEqual(used, 24)
                    XCTAssertEqual(files.files[changedPath], replacement)
                }
            }
        }
    }

    func testChangedIdentityAndMissingLoginNeverUseOtherCardCredentials() async {
        let files = fixture()
        files.files["/test/personal/auth.json"] = Self.credential(b, token: "wrong")
        files.files["/test/main/auth.json"] = Self.credential(b, token: "wrong-default")
        let http = RoutingHTTPClient { _ in XCTFail("No matching credential may reach the API"); return Self.response(99) }
        let candidate = provider(auth(a, files: files, keychain: FakeKeychain(Self.credential(b, token: "wrong-keychain"))), http: http)
        let hasCredentials = await candidate.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
        let result = await candidate.refresh()
        XCTAssertNotNil(result.errorCategory)
    }

    func testExpiredAccessTokenUsesMatchingSavedLoginWithoutRefresh() async {
        let files = fixture()
        let expired = "header." + Data(#"{"exp":1}"#.utf8).base64EncodedString() + ".signature"
        files.files["/test/main/auth.json"] = Self.credential(a, token: expired)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.headers["Authorization"], "Bearer saved-a")
            return Self.response(12)
        }
        let result = await provider(auth(a, files: files, keychain: FakeKeychain()), http: http).refresh()
        XCTAssertNil(result.errorCategory)
        XCTAssertEqual(files.files["/test/main/auth.json"], Self.credential(a, token: expired))
    }

    func testDefaultProbeCannotRotateASwapTokenWhenAccountAssemblyWasDeferred() throws {
        let files = fixture()
        let registry = files.files["/test/.local/share/codex-swap/accounts.json"]!
        files.files["/custom/accounts.json"] = registry
        let store = CodexAuthStore(environment: FakeEnvironment([
            "CODEX_HOME": "/test/main", "XSWAP_HOME": "/custom"
        ]), files: files, keychain: FakeKeychain())
        let credential = try XCTUnwrap(store.loadAuthCandidates().first)
        XCTAssertTrue(credential.readOnly)
        XCTAssertNil(credential.auth.tokens?.refreshToken)
        XCTAssertThrowsError(try store.save(credential))
    }

    func testRemovingSwapRegistryKeepsKnownOwnershipAndExistingCardID() async throws {
        let files = fixture()
        let store = ProviderAccountsStore(defaults: try defaults())
        let initial = await assembly(files, store: store)
        files.files.removeValue(forKey: "/test/.local/share/codex-swap/accounts.json")
        let next = await assembly(files, store: store)
        XCTAssertEqual(next.codexCards.count, 1)
        XCTAssertEqual(next.codexCards.first?.id, initial.codexCards.first { $0.identity == a }?.id)
        XCTAssertEqual(next.codexCards.first?.allowsUnattributedHistory, false)
    }

    func testResetCreditServiceNeverConsumesAnotherAccountsCredit() async {
        let files = fixture()
        let identity = a
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], identity.accountID)
            XCTAssertNotEqual(request.headers["Authorization"], "Bearer saved-b")
            if request.method == "POST" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
            }
            // Switch the default while the credit lookup is pending. The claim still belongs to A.
            files.files["/test/main/auth.json"] = files.files["/test/work/auth.json"]
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"credits":[{"id":"a-credit","expires_at":1900000000,"status":"available"}]}"#.utf8))
        }
        let service = CodexResetClaimService(authStore: auth(a, files: files, keychain: FakeKeychain()),
            usageClient: CodexUsageClient(http: http), refreshAfterClaim: {})
        let result = await service.claim(creditExpiringAt: expiry, redeemRequestID: "test-only")
        XCTAssertEqual(result, .success)
        XCTAssertEqual(http.requests.filter { $0.method == "POST" }.count, 1)
    }
}
