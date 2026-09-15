import os
import XCTest
@testable import OpenUsage

@MainActor
final class CodexSwapMaintainerReviewTests: XCTestCase {
    private let a = CodexAccountIdentity(accountID: "workspace-a", email: "personal@example.com")!
    private let b = CodexAccountIdentity(accountID: "workspace-b", email: "work@example.com")!
    private let environment = FakeEnvironment(["CODEX_HOME": "/test/default", "XSWAP_HOME": "/test/swap"])

    private func defaults() throws -> UserDefaults {
        let suite = "CodexSwapMaintainer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func files(mainHome: String = "/test/default") -> FakeFiles {
        FakeFiles([
            "/test/swap/accounts.json": #"""
            {"schemaVersion":1,"mainHome":"\#(mainHome)","accounts":[
              {"number":1,"alias":"Work","home":"/test/work",
               "identity":{"accountId":"workspace-b","email":"work@example.com"}}
            ]}
            """#,
            "/test/work/auth.json": CodexSwapAccountTests.credential(b, token: "saved-work")
        ])
    }

    private func observer(files: FakeFiles, keychain: any KeychainAccessing) -> DefaultAccountObserver {
        DefaultAccountObserver(environment: environment, files: files, keychain: keychain,
                               homeDirectory: { URL(fileURLWithPath: "/test") })
    }

    private func provider(_ card: CodexAccountCard, files: FakeFiles, keychain: any KeychainAccessing,
                          http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: CodexAuthStore(environment: environment, files: files, keychain: keychain,
                                     expectedIdentity: card.identity, additionalAuthHomes: card.authHomes),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(allowsUnattributedHistory: false),
            allowsUnattributedHistory: false, pricing: { TestPricing.bundled })
    }

    private func card(_ identity: CodexAccountIdentity, id: String = "codex") -> CodexAccountCard {
        CodexAccountCard(id: id, identity: identity, displayName: id, authHomes: [],
                         logHomes: [], allowsUnattributedHistory: false)
    }

    nonisolated private static func response(status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(
            #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":17,"limit_window_seconds":18000}}}"#.utf8))
    }

    func testCodexAccountExportOmitsUnresolvedClaudeWithoutBlockingOtherProviders() throws {
        let defaults = try defaults()
        let providers = [ClaudeProvider().provider, CodexProvider.makeProvider(), GrokProvider().provider]
        let descriptors = providers.map {
            WidgetDescriptor.usageTrend(provider: $0)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache")
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: Date()), totalTokens: 123, costUSD: 1)
        ]))
        for model in providers {
            cache.store(.init(providerID: model.id, displayName: model.displayName,
                              lines: [], usageHistory: history),
                        producedByIdentityKey: model.id == "codex" ? a.key : nil)
        }
        let store = WidgetDataStore(registry: registry, providers: [], cache: cache, defaults: defaults,
                                    providerIdentityKeys: ["codex": a.key])
        let document = store.localHistoryDocument(deviceID: "test", deviceName: "Test")
        XCTAssertNoThrow(try document.validate())
        XCTAssertNotNil(document.providers["codex"])
        XCTAssertNotNil(document.providers["grok"])
        XCTAssertNil(document.providers["claude"])

        let legacy = WidgetDataStore(registry: registry, providers: [], cache: cache, defaults: defaults)
            .localHistoryDocument(deviceID: "legacy", deviceName: "Legacy")
        XCTAssertEqual(legacy.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(legacy.providers["claude"])
        XCTAssertNoThrow(try legacy.validate())
    }

    func testKeychainOnlyDefaultGetsItsOwnStableCardBesideSwap() async throws {
        let files = files()
        let keychain = BackgroundCheckingKeychain(CodexSwapAccountTests.credential(a, token: "keychain-personal"))
        let observer = observer(files: files, keychain: keychain)
        let accounts = ProviderAccountsStore(defaults: try defaults())
        let first = await ProviderAccountAssembly.make(observer: observer, accountsStore: accounts, families: ["codex"])
        XCTAssertEqual(first.codexCards.count, 2)
        let personal = try XCTUnwrap(first.codexCards.first { $0.identity == a })
        XCTAssertEqual(personal.id, "codex")
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.headers["Authorization"], "Bearer keychain-personal")
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "workspace-a")
            return Self.response()
        }
        let snapshot = await provider(personal, files: files, keychain: keychain, http: http).refresh()
        XCTAssertNil(snapshot.errorCategory)
        files.files["/test/default/auth.json"] = CodexSwapAccountTests.credential(b, token: "default-work")
        let next = await ProviderAccountAssembly.make(observer: observer, accountsStore: accounts, families: ["codex"])
        XCTAssertEqual(first.codexCards.map(\.id), next.codexCards.map(\.id))
        XCTAssertFalse(keychain.readOnMainThread)
        XCTAssertEqual(keychain.writes, 0)
    }

    func testEveryKeychainCredentialRecheckRunsOffTheMainThread() async {
        let keychain = BackgroundCheckingKeychain(CodexSwapAccountTests.credential(a, token: "keychain-personal"))
        let http = RoutingHTTPClient { _ in Self.response() }
        let snapshot = await provider(card(a), files: files(), keychain: keychain, http: http).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertGreaterThanOrEqual(keychain.reads, 4, "Include the checks before and after each request")
        XCTAssertFalse(keychain.readOnMainThread, "A security subprocess must never block the MainActor")
        XCTAssertEqual(keychain.writes, 0)
    }

    func testKeychainOverlapAndChangedKeychainNeverBorrowAnotherAccountsLimits() async throws {
        for changesAccount in [false, true] {
            let files = files()
            files.files["/test/default/auth.json"] = CodexSwapAccountTests.credential(a, token: "rejected-file")
            let keychain = BackgroundCheckingKeychain(CodexSwapAccountTests.credential(a, token: "stale-keychain"))
            let assembly = await ProviderAccountAssembly.make(observer: observer(files: files, keychain: keychain),
                accountsStore: ProviderAccountsStore(defaults: try defaults()), families: ["codex"])
            XCTAssertEqual(assembly.codexCards.count, 2, "Matching file and Keychain logins share a card")
            let personal = try XCTUnwrap(assembly.codexCards.first { $0.identity == a })
            let replacement = CodexSwapAccountTests.credential(changesAccount ? b : a, token: "replacement-keychain")
            let http = RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "workspace-a")
                let token = request.headers["Authorization"]
                if token == "Bearer rejected-file" { return Self.response(status: 401) }
                if token == "Bearer stale-keychain" {
                    keychain.replaceExternally(with: replacement)
                    return Self.response()
                }
                XCTAssertFalse(changesAccount, "The other identity must never supply this card's limits")
                XCTAssertEqual(token, "Bearer replacement-keychain")
                return Self.response()
            }
            let snapshot = await provider(personal, files: files, keychain: keychain, http: http).refresh()
            XCTAssertEqual(snapshot.errorCategory != nil, changesAccount,
                           "Discard usage returned for a replaced Keychain login")
            XCTAssertFalse(keychain.readOnMainThread)
            XCTAssertEqual(keychain.writes, 0)
        }
    }

    func testCustomMainHomeRemainsAvailableForAccountWithoutASavedSlot() async throws {
        let files = files(mainHome: "/test/custom-main")
        files.files["/test/custom-main/auth.json"] = CodexSwapAccountTests.credential(a, token: "custom-personal")
        let keychain = FakeKeychain()
        let assembly = await ProviderAccountAssembly.make(observer: observer(files: files, keychain: keychain),
            accountsStore: ProviderAccountsStore(defaults: try defaults()), families: ["codex"])
        let personal = try XCTUnwrap(assembly.codexCards.first { $0.identity == a })
        XCTAssertTrue(personal.authHomes.contains("/test/custom-main"))
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer custom-personal")
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "workspace-a")
            return Self.response()
        }
        let runtime = provider(personal, files: files, keychain: keychain, http: http)
        let hasCredentials = await runtime.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
    }

    func testUnownedCachedSpendIsRemovedBeforeAnExpiredLoginOrCacheHitCanKeepIt() async throws {
        for persistedFreshness in [false, true] {
            let defaults = try defaults()
            let model = CodexProvider.makeProvider()
            let files = files()
            let expired = "header." + Data(#"{"exp":1}"#.utf8).base64EncodedString() + ".signature"
            files.files["/test/default/auth.json"] = CodexSwapAccountTests.credential(a, token: expired)
            let http = RoutingHTTPClient { _ in XCTFail("Expired token must not reach the API"); return Self.response(status: 401) }
            let runtime = provider(card(a), files: files, keychain: FakeKeychain(), http: http)
            let registry = WidgetRegistry.from([runtime])
            let descriptor = try XCTUnwrap(registry.historyDescriptorsByProvider["codex"])
            let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: Date()), totalTokens: 999, costUSD: 5)
            ]))
            let original = UsageHistorySnapshotRenderer.render(
                local: .init(providerID: "codex", displayName: model.displayName,
                             lines: [.badge(label: "Plan", text: "Pro", colorHex: "#ffffff")],
                             refreshedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                             usageHistory: history),
                history: history, descriptor: descriptor, combined: false)
            ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache")
                .store(original, producedByIdentityKey: a.key)
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache",
                                              allowsPersistedFreshness: persistedFreshness)
            let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults,
                                        providerIdentityKeys: ["codex": a.key])
            XCTAssertEqual(cache.snapshot(providerID: "codex") != nil, persistedFreshness,
                           "Removing history must not count as a fresh usage write")
            XCTAssertNil(store.snapshots["codex"]?.usageHistory, "Clear history before the first refresh")
            XCTAssertNil(store.snapshots["codex"]?.line(label: "Today"))
            XCTAssertEqual(store.snapshots["codex"]?.line(label: "Plan"), original.line(label: "Plan"))
            _ = await store.refresh(providerID: "codex", force: false)
            _ = await store.refresh(providerID: "codex", force: true)
            XCTAssertNotNil(store.providerErrors["codex"])
            XCTAssertNil(store.localSnapshots["codex"]?.usageHistory)
            XCTAssertNil(store.localHistoryDocument(deviceID: "test", deviceName: "Test").providers["codex"])
            let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache")
            XCTAssertNil(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"]?.usageHistory)
            XCTAssertEqual(reloaded.producedByIdentityKey(providerID: "codex"), a.key)
            XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"]?.refreshedAt,
                           original.refreshedAt, "Clearing excluded history must not make old limits fresh")
        }
    }
}

private final class BackgroundCheckingKeychain: KeychainAccessing, Sendable {
    private struct State { var value: String; var reads = 0; var writes = 0; var readOnMainThread = false }
    private let state: OSAllocatedUnfairLock<State>
    init(_ value: String) { state = OSAllocatedUnfairLock(initialState: State(value: value)) }
    func replaceExternally(with value: String) { state.withLock { $0.value = value } }
    var reads: Int { state.withLock { $0.reads } }
    var writes: Int { state.withLock { $0.writes } }
    var readOnMainThread: Bool { state.withLock { $0.readOnMainThread } }

    func readGenericPassword(service: String) throws -> String? {
        state.withLock {
            $0.reads += 1
            $0.readOnMainThread = $0.readOnMainThread || Thread.isMainThread
            return $0.value
        }
    }

    func writeGenericPassword(service: String, value: String) throws {
        state.withLock { $0.writes += 1 }
    }
}
