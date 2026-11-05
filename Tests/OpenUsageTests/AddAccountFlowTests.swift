import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AddAccountFlowTests: XCTestCase {
    func testFailedSignInCanBeRetriedAndAddsTheAccount() async throws {
        let store = makeStore()
        var attempts = 0
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in
            attempts += 1
            return attempts == 1
                ? StubLogin { _ in throw LoginError.invalidCode }
                : StubLogin { _ in ("claude@example.com", .oauth(OAuthTokens(accessToken: "access"))) }
        }
        flow.choose(.claude)
        try await waitUntil { flow.errorMessage != nil }
        XCTAssertEqual(flow.errorMessage, LoginError.invalidCode.localizedDescription)
        XCTAssertTrue(store.accounts.isEmpty)

        flow.signIn()
        try await waitUntil { flow.isFinished }
        XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(store.accounts.map(\.label), ["claude@example.com"])
        XCTAssertEqual(store.accounts.map(\.kind), [.claude])
    }

    func testSigningInAgainReplacesTheSignInAndAddsNoAccount() async throws {
        let store = makeStore()
        let account = store.add(kind: .claude, label: "Personal", credential: .oauth(OAuthTokens(accessToken: "old")))
        var replaced: [(AccountCredential, String)] = []
        let flow = AddAccountFlow(
            store: store,
            openURL: { _ in },
            login: { _, _, _, _ in StubLogin { _ in ("someone@example.com", .oauth(OAuthTokens(accessToken: "new"))) } },
            replaceCredential: { replaced.append(($0, $1)) },
            signingInAgainTo: account
        )
        XCTAssertEqual(flow.provider, .claude, "the sheet opens on the account's sign-in, not the provider list")
        XCTAssertFalse(flow.isWorking, "creating the flow must not open a browser")

        flow.startSigningInAgain()
        try await waitUntil { flow.isFinished }

        XCTAssertEqual(replaced.map(\.1), [account.cardID])
        XCTAssertEqual(store.accounts.map(\.label), ["Personal"])
    }

    func testAPIKeyIsSavedUnderTheTypedName() async throws {
        let vault = InMemoryCredentialVault()
        let store = makeStore(vault: vault)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(OpenRouterFixtures.standardKey.utf8)) }
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { kind, _, _, _ in APIKeyLogin(kind: kind, http: http) }
        flow.choose(.openrouter)
        XCTAssertFalse(flow.isWorking)
        XCTAssertFalse(flow.canAddKey)

        flow.apiKey = "  sk-or-key  "
        flow.accountName = " Work "
        flow.addKey()
        try await waitUntil { flow.isFinished }
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.label, "Work")
        XCTAssertEqual(try vault.load(account.id), .apiKey("sk-or-key"))
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer sk-or-key"])
    }

    func testARejectedAPIKeyIsNotAdded() async throws {
        let store = makeStore()
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { kind, _, _, _ in APIKeyLogin(kind: kind, http: http) }
        flow.choose(.openrouter)

        flow.apiKey = "sk-or-typo"
        flow.addKey()
        try await waitUntil { flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "OpenRouter rejected the API key.")
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testCopilotAsksForAMethodAndOrganizationBillingAddsTheOrganization() async throws {
        let vault = InMemoryCredentialVault()
        let store = makeStore(vault: vault)
        var started: [(ProviderAuthMethod, String)] = []
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, method, organization, _ in
            started.append((method, organization))
            return StubLogin { input in
                var iterator = input.makeAsyncIterator()
                let token = await iterator.next() ?? ""
                return (organization, .apiKey(token))
            }
        }
        flow.choose(.copilot)
        XCTAssertNil(flow.method, "Copilot asks how to add it")
        XCTAssertFalse(flow.isWorking)

        flow.choose(.organizationToken)
        flow.apiKey = "github_pat_1"
        XCTAssertFalse(flow.canAddKey, "an organization is required")
        flow.organization = " Acme "
        flow.addKey()
        try await waitUntil { flow.isFinished }

        XCTAssertEqual(started.map(\.0), [.organizationToken])
        XCTAssertEqual(started.map(\.1), ["Acme"])
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.kind, .copilot)
        XCTAssertEqual(account.label, "Acme")
        XCTAssertEqual(account.organization, "Acme")
        XCTAssertEqual(try vault.load(account.id), .apiKey("github_pat_1"))
    }

    func testBackStopsTheSignInAndReturnsToTheListWithTheProviderSelected() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        let cancelled = CancellationFlag()
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in
            StubLogin(prompt: .browser(url, acceptsPastedCode: true)) { _ in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await cancelled.set()
                    throw error
                }
                return ("late", .oauth(OAuthTokens(accessToken: "access")))
            }
        }
        flow.choose(.codex)
        try await waitUntil { flow.prompt != nil }
        flow.pastedCode = "half-typed"

        flow.back()

        XCTAssertNil(flow.provider)
        XCTAssertEqual(flow.selection, .provider(.codex))
        XCTAssertNil(flow.prompt)
        XCTAssertNil(flow.errorMessage)
        XCTAssertFalse(flow.isWorking)
        XCTAssertEqual(flow.pastedCode, "")
        XCTAssertFalse(flow.isFinished)
        for _ in 0..<200 where !(await cancelled.isSet) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let loginWasCancelled = await cancelled.isSet
        XCTAssertTrue(loginWasCancelled, "back() left the sign-in running")
        XCTAssertNil(flow.errorMessage)
        XCTAssertFalse(flow.isFinished)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testTheBrowserOpensOnceEachTimeASignInAttemptAsksForIt() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        var opened: [URL] = []
        var attempts = 0
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, _, _, _ in
            attempts += 1
            switch attempts {
            case 1: return StubLogin(prompt: .browser(url, acceptsPastedCode: false)) { _ in throw LoginError.invalidCode }
            case 2: return StubLogin { _ in throw LoginError.invalidCode }
            default: return StubLogin(prompt: .browser(url, acceptsPastedCode: false)) { _ in ("rob", .oauth(OAuthTokens(accessToken: "access"))) }
            }
        }
        flow.choose(.claude)
        try await waitUntil { flow.errorMessage != nil }
        XCTAssertEqual(opened, [url], "the browser opens when the sign-in asks for it")

        flow.signIn()
        try await waitUntil { attempts == 2 && flow.errorMessage != nil }
        XCTAssertEqual(opened, [url], "Try Again opened the browser before the new attempt asked for it")

        flow.signIn()
        try await waitUntil { flow.isFinished }
        XCTAssertEqual(opened, [url, url], "the new attempt's prompt opens the browser again")
    }

    func testATokenPageOpensOnItsOwnAndThePastedTokenFinishesTheSignIn() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/show-auth-token"))
        var opened: [URL] = []
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, _, _, _ in
            StubLogin(prompt: .browserToken(url)) { input in
                var iterator = input.makeAsyncIterator()
                return ("token:\(await iterator.next() ?? "")", .oauth(OAuthTokens(accessToken: "key")))
            }
        }
        flow.choose(.claude)
        try await waitUntil { flow.prompt != nil }
        XCTAssertEqual(opened, [url])
        XCTAssertFalse(flow.canSubmitCode)

        flow.pastedCode = "abc123"
        flow.submitCode()
        try await waitUntil { flow.isFinished }
        XCTAssertEqual(store.accounts.map(\.label), ["token:abc123"])
    }

    func testTheDeviceCodePageOpensOnlyOnRequest() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/device"))
        var opened: [URL] = []
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, _, _, _ in
            StubLogin(prompt: .deviceCode(userCode: "ABCD-EFGH", verificationURL: url)) { _ in
                try await Task.sleep(for: .seconds(30))
                return ("late", .oauth(OAuthTokens(accessToken: "access")))
            }
        }
        flow.choose(.grok)
        try await waitUntil { flow.prompt != nil }
        XCTAssertTrue(opened.isEmpty, "a device code has to be read before its page opens")

        flow.openBrowser()
        XCTAssertEqual(opened, [url])
        flow.cancel()
    }

    func testAHubErrorShowsOnlyAfterConnectAndClearsOnceTheUserTypes() async throws {
        let flow = AddAccountFlow(store: makeStore(), connectHub: { _, _ in throw ProviderError.unavailable("Use https for hub.example.com.") })
        flow.chooseHub()
        flow.hubURL = "http://hub.example.com"
        flow.apiKey = "mgmt-key"
        XCTAssertNil(flow.errorMessage, "typing shows no error")

        flow.connect()
        try await waitUntil { flow.errorMessage != nil }
        flow.hubURL = "https://hub.example.com"
        XCTAssertNil(flow.errorMessage, "editing the address hides the error until Connect")

        flow.connect()
        try await waitUntil { flow.errorMessage != nil }
        flow.apiKey = "other-key"
        XCTAssertNil(flow.errorMessage, "editing the key hides the error until Connect")
    }

    func testAddKeyWhileSavingStartsNoSecondSave() async throws {
        let store = makeStore()
        var started = 0
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in
            started += 1
            return StubLogin { _ in
                try await Task.sleep(for: .milliseconds(100))
                return ("key", .apiKey("sk-or-key"))
            }
        }
        flow.choose(.openrouter)
        flow.apiKey = "sk-or-key"
        for _ in 0..<3 { flow.addKey() }
        XCTAssertFalse(flow.canAddKey, "a save in flight keeps Return from starting another")
        try await waitUntil { flow.isFinished }
        XCTAssertEqual(started, 1)
        XCTAssertEqual(store.accounts.map(\.label), ["key"])
    }

    private func makeStore(vault: InMemoryCredentialVault = InMemoryCredentialVault()) -> AccountStore {
        let defaults = isolatedDefaults()
        return AccountStore(defaults: defaults, vault: vault)
    }
}

private actor CancellationFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}

private struct StubLogin: ProviderLogin {
    var prompt: LoginPrompt?
    let finish: @Sendable (AsyncStream<String>) async throws -> (label: String, credential: AccountCredential)

    init(prompt: LoginPrompt? = nil, finish: @escaping @Sendable (AsyncStream<String>) async throws -> (label: String, credential: AccountCredential)) {
        self.prompt = prompt
        self.finish = finish
    }

    func login(prompt show: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        if let prompt { await show(prompt) }
        return try await finish(pastedCode)
    }
}
