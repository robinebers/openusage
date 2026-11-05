import Foundation
import XCTest
@testable import OpenUsage

/// Copilot on a company's GHE.com domain (#1602): the Domain step, the hosts each sign-in uses, and how
/// enterprise accounts are told apart from github.com ones.
@MainActor
final class CopilotEnterpriseTests: XCTestCase {
    nonisolated private static let enterprise = GitHubDomain.enterprise("octocorp.ghe.com")
    nonisolated private static let usage = #"{"copilot_plan":"enterprise","quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":240,"percent_remaining":80}}}"#

    func testTheDomainIsNormalizedAndOnlyGHEComIsAccepted() {
        for blank in ["", "   ", "github.com", " GitHub.com ", "https://github.com/settings/copilot", "www.github.com"] {
            XCTAssertEqual(GitHubDomain(parsing: blank), .github, blank)
        }
        for typed in ["octocorp", "OctoCorp", " octocorp.ghe.com ", "https://octocorp.ghe.com/login/device", "octocorp.ghe.com/?x=1", "octocorp.GHE.com#a"] {
            XCTAssertEqual(GitHubDomain(parsing: typed), Self.enterprise, typed)
        }
        XCTAssertEqual(GitHubDomain(parsing: "octo-corp-2"), .enterprise("octo-corp-2.ghe.com"))
        for invalid in ["github.acme.com", "ghe.com", ".ghe.com", "a.b.ghe.com", "-octo.ghe.com", "octo-.ghe.com", "octo corp", "octo_corp.ghe.com", "octocorp.ghe.com:8443"] {
            XCTAssertNil(GitHubDomain(parsing: invalid), invalid)
        }
    }

    func testGitHubComSignInKeepsTodaysHostsAndReadsNoUsage() async throws {
        let http = Self.gitHub(usage: .json("{}", status: 404))

        let result = try await CopilotLogin(domain: .github, http: http).login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })

        XCTAssertEqual(result.label, "robin")
        XCTAssertEqual(result.credential.identity, "github:42")
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [
            "https://github.com/login/device/code",
            "https://github.com/login/oauth/access_token",
            "https://api.github.com/user"
        ])
        XCTAssertEqual(Self.clientID(http.requests[0]), CopilotLogin.clientID)
    }

    func testEnterpriseSignInUsesTheDomainsHostsAndChecksTheSeatOnce() async throws {
        let http = Self.gitHub(usage: .json(Self.usage))
        let prompt = DeviceCodeCapture()

        let result = try await CopilotLogin(domain: Self.enterprise, http: http).login(prompt: { prompt.store($0) }, pastedCode: AsyncStream { $0.finish() })

        XCTAssertEqual(result.label, "robin")
        XCTAssertEqual(result.credential.identity, "github:octocorp.ghe.com:42")
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [
            "https://octocorp.ghe.com/login/device/code",
            "https://octocorp.ghe.com/login/oauth/access_token",
            "https://api.octocorp.ghe.com/user",
            "https://api.octocorp.ghe.com/copilot_internal/user"
        ])
        XCTAssertEqual(Self.clientID(http.requests[0]), CopilotLogin.clientID, "the same client id as github.com")
        XCTAssertEqual(prompt.verificationURL?.host(), "octocorp.ghe.com")
    }

    func testRefreshReadsUsageFromTheAccountsDomain() async throws {
        for (domain, host) in [(nil, "api.github.com"), ("octocorp.ghe.com", "api.octocorp.ghe.com")] {
            let account = Account(kind: .copilot, label: "robin", domain: domain)
            let vault = InMemoryCredentialVault()
            try vault.save(.oauth(OAuthTokens(accessToken: "token")), for: account.id)
            let http = RoutingHTTPClient { _ in .json(Self.usage) }

            let result = await AccountProviderRuntime(account: account, vault: vault, http: http).refresh()

            XCTAssertNoThrow(try result.get(), host)
            XCTAssertEqual(http.requests.map(\.url.absoluteString), ["https://\(host)/copilot_internal/user"])
        }
    }

    func testAnEnterpriseAccountWithoutASeatIsNeverAdded() async throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let http = Self.gitHub(usage: .json(#"{"message":"Not Found"}"#, status: 404))
        let flow = Self.flow(store) { CopilotLogin(domain: $0, http: http) }

        flow.choose(.copilot)
        flow.choose(.oauth)
        XCTAssertTrue(flow.isEnteringDomain, "Copilot's own sign-in asks for the domain before any code")
        XCTAssertTrue(http.requests.isEmpty)
        flow.domain = "octocorp"
        flow.continueToSignIn()
        try await waitUntil { flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "robin has no Copilot seat on octocorp.ghe.com. Ask your GitHub admin for one, then try again.")
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(flow.canChangeDomain)

        flow.changeDomain()
        XCTAssertTrue(flow.isEnteringDomain)
        XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(flow.domain, "octocorp", "Change Domain keeps what was typed")
    }

    func testAnUnreachableDomainSaysSo() async throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let http = RoutingHTTPClient { _ in throw URLError(.cannotFindHost) }
        let flow = Self.flow(store) { CopilotLogin(domain: $0, http: http) }

        flow.choose(.copilot)
        flow.choose(.oauth)
        flow.domain = "https://octocrop.ghe.com/"
        flow.continueToSignIn()
        try await waitUntil { flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "Couldn’t reach octocrop.ghe.com. Check the address and your connection.")
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testAnInvalidDomainStaysOnTheDomainStep() async throws {
        var logins = 0
        let flow = Self.flow(AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())) { _ in
            logins += 1
            return CopilotLogin(http: RoutingHTTPClient { _ in .json("{}", status: 500) })
        }

        flow.choose(.copilot)
        flow.choose(.oauth)
        flow.domain = "github.acme.com"
        flow.continueToSignIn()

        XCTAssertEqual(flow.errorMessage, GitHubDomain.invalidMessage)
        XCTAssertTrue(flow.isEnteringDomain)
        XCTAssertFalse(flow.isWorking)
        XCTAssertEqual(logins, 0)

        flow.domain = "github.acme"
        XCTAssertNil(flow.errorMessage, "editing the domain clears the error")
    }

    func testTheDomainIsSavedOnTheAccountAndGitHubComSavesNone() async throws {
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        let http = Self.gitHub(usage: .json(Self.usage))

        for typed in ["", "octocorp.ghe.com"] {
            let flow = Self.flow(store) { CopilotLogin(domain: $0, http: http) }
            flow.choose(.copilot)
            flow.choose(.oauth)
            flow.domain = typed
            flow.continueToSignIn()
            try await waitUntil { flow.isFinished || flow.errorMessage != nil }
            XCTAssertNil(flow.errorMessage, typed)
        }

        XCTAssertEqual(store.accounts.map(\.domain), [nil, "octocorp.ghe.com"], "the same user id on another domain is another account")
        XCTAssertEqual(store.accounts.map { AccountProviderRuntime.provider(for: $0).domain }, [nil, "octocorp.ghe.com"])
        let saved = try XCTUnwrap(vault.load(store.accounts[1].id))
        guard case .oauth(let tokens) = saved else { return XCTFail("expected an OAuth sign-in") }
        XCTAssertFalse(tokens.extras.values.contains("octocorp.ghe.com"), "the domain lives on the account, not in the Keychain item")
    }

    func testTheSameEnterpriseUserIsNotAddedTwice() async throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let http = Self.gitHub(usage: .json(Self.usage))
        store.add(kind: .copilot, label: "robin", domain: "octocorp.ghe.com", credential: .oauth(OAuthTokens(
            accessToken: "old", extras: [OAuthTokens.identityKey: "github:octocorp.ghe.com:42"]
        )))

        let flow = Self.flow(store) { CopilotLogin(domain: $0, http: http) }
        flow.choose(.copilot)
        flow.choose(.oauth)
        flow.domain = "OctoCorp"
        flow.continueToSignIn()
        try await waitUntil { flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "This account is already added as robin.")
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testSigningInAgainReusesTheSavedDomainAndSkipsTheDomainStep() async throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let account = store.add(kind: .copilot, label: "robin", domain: "octocorp.ghe.com", credential: .oauth(OAuthTokens(accessToken: "old")))
        var domains: [GitHubDomain] = []
        let flow = AddAccountFlow(
            store: store,
            openURL: { _ in },
            login: { _, _, _, domain in
                domains.append(domain)
                return CopilotLogin(domain: domain, http: Self.gitHub(usage: .json(Self.usage)))
            },
            replaceCredential: { _, _ in },
            signingInAgainTo: account
        )

        XCTAssertFalse(flow.isEnteringDomain)
        XCTAssertFalse(flow.canChangeDomain)
        flow.startSigningInAgain()
        try await waitUntil { flow.isFinished }

        XCTAssertEqual(domains, [Self.enterprise])
    }

    func testAnAccountSavedBeforeDomainsSignsInAtGitHubCom() throws {
        let defaults = isolatedDefaults()
        let id = UUID()
        let stored: [[String: Any]] = [["id": id.uuidString, "kind": "copilot", "label": "robin", "addedAt": 0]]
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: AccountStore.storageKey)

        let (accounts, unreadable) = AccountStore.load(from: defaults)

        XCTAssertTrue(unreadable.isEmpty)
        XCTAssertEqual(accounts.map(\.id), [id])
        XCTAssertNil(accounts[0].domain)
        XCTAssertEqual(GitHubDomain(saved: accounts[0].domain), .github)
        XCTAssertNil(AccountProviderRuntime.provider(for: accounts[0]).domain)
    }

    private static func flow(_ store: AccountStore, login: @escaping (GitHubDomain) -> CopilotLogin) -> AddAccountFlow {
        AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, domain in login(domain) }
    }

    /// A GitHub that signs in user 42, `robin`, on whatever host is asked.
    nonisolated private static func gitHub(usage: HTTPResponse) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            let host = request.url.host() ?? ""
            return switch request.url.path {
            case "/login/device/code":
                .json(#"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://\#(host)/login/device","expires_in":600,"interval":1}"#)
            case "/login/oauth/access_token": .json(#"{"access_token":"copilot-access"}"#)
            case "/user": .json(#"{"id":42,"login":"robin"}"#)
            case "/copilot_internal/user": usage
            default: .json("{}", status: 404)
            }
        }
    }

    private static func clientID(_ request: HTTPRequest) -> String? {
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return URLComponents(string: "https://example.invalid/?\(body)")?.queryItems?.first { $0.name == "client_id" }?.value
    }
}

private final class DeviceCodeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    var verificationURL: URL? { lock.withLock { url } }

    func store(_ prompt: LoginPrompt) {
        guard case .deviceCode(_, let verificationURL) = prompt else { return }
        lock.withLock { url = verificationURL }
    }
}
