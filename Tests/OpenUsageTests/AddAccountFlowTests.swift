import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AddAccountFlowTests: XCTestCase {
    func testFailedSignInCanBeRetriedAndAddsTheAccount() async throws {
        let store = makeStore()
        var attempts = 0
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _ in
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

    func testPastedCodeReachesTheWaitingSignIn() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _ in
            StubLogin(prompt: .browser(url, acceptsPastedCode: true)) { input in
                var iterator = input.makeAsyncIterator()
                let code = await iterator.next() ?? ""
                return ("code:\(code)", .oauth(OAuthTokens(accessToken: "access")))
            }
        }
        flow.choose(.claude)
        try await waitUntil { flow.prompt != nil }
        XCTAssertFalse(flow.canSubmitCode)

        flow.pastedCode = "abc123"
        flow.submitCode()
        try await waitUntil { flow.isFinished }
        XCTAssertEqual(store.accounts.map(\.label), ["code:abc123"])
    }

    func testAPIKeyIsSavedUnderTheTypedName() async throws {
        let vault = InMemoryCredentialVault()
        let store = makeStore(vault: vault)
        let flow = AddAccountFlow(store: store)
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
    }

    func testChoosingAProviderGoesStraightToItsStep() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        var started: [ProviderKind] = []
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { kind, _, _ in
            started.append(kind)
            return StubLogin(prompt: .browser(url, acceptsPastedCode: false)) { _ in
                try await Task.sleep(for: .seconds(30))
                return ("late", .oauth(OAuthTokens(accessToken: "access")))
            }
        }
        XCTAssertNil(flow.selection, "The list opens with nothing chosen")

        flow.choose(.zai)
        XCTAssertEqual(flow.provider, .zai)
        XCTAssertFalse(flow.isWorking, "An API-key provider waits for the key")
        XCTAssertTrue(started.isEmpty)

        flow.back()
        XCTAssertEqual(flow.selection, .zai)
        flow.choose(.claude)
        XCTAssertEqual(flow.provider, .claude)
        try await waitUntil { flow.prompt != nil }
        XCTAssertEqual(started, [.claude])
        flow.cancel()
    }

    func testCopilotAsksForAMethodAndOrganizationBillingAddsTheOrganization() async throws {
        let vault = InMemoryCredentialVault()
        let store = makeStore(vault: vault)
        var started: [(ProviderAuthMethod, String)] = []
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, method, organization in
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

    func testCancelStopsTheSignInWithoutAddingAnAccount() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/device"))
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _ in
            StubLogin(prompt: .deviceCode(userCode: "ABCD-EFGH", verificationURL: url)) { _ in
                try await Task.sleep(for: .seconds(30))
                return ("late", .oauth(OAuthTokens(accessToken: "access")))
            }
        }
        flow.choose(.grok)
        try await waitUntil { flow.prompt != nil }

        flow.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(flow.isFinished)
        XCTAssertNil(flow.errorMessage)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testBackStopsTheSignInAndReturnsToTheListWithTheProviderSelected() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        let cancelled = CancellationFlag()
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _ in
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
        XCTAssertEqual(flow.selection, .codex)
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
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testTheBrowserOpensOnceEachTimeASignInAttemptAsksForIt() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        var opened: [URL] = []
        var attempts = 0
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, _, _ in
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

    func testTheDeviceCodePageOpensOnlyOnRequest() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/device"))
        var opened: [URL] = []
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, _, _ in
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

    private func makeStore(vault: InMemoryCredentialVault = InMemoryCredentialVault()) -> AccountStore {
        let defaults = isolatedDefaults()
        return AccountStore(defaults: defaults, vault: vault)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the add-account flow")
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
