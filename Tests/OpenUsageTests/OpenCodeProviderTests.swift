import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private nonisolated static let usage = #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-07-12T13:30:00Z"},"weekly":{"percent":8,"resetsAt":"2026-07-13T00:00:00Z"},"monthly":{"percent":40,"resetsAt":"2026-08-04T11:18:32Z"}}}"#

    private nonisolated static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }

    private static let signIn = AccountCredential.oauth(OAuthTokens(accessToken: "console", extras: [OpenCodeLogin.orgKey: "wrk_01"]))

    private func runtime(
        _ credential: AccountCredential,
        now: @escaping () -> Date = Date.init,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) throws -> (AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .opencodeGo, label: "OpenCode")
        let vault = InMemoryCredentialVault()
        try vault.save(credential, for: account.id)
        let http = RoutingHTTPClient(handler: handler)
        return (AccountProviderRuntime(account: account, vault: vault, http: http, now: now), http)
    }

    func testAccountSavedUnderTheOldRawValueStillLoads() throws {
        let defaults = isolatedDefaults()
        let saved = #"[{"id":"8AD3B217-0000-4000-8000-000000000000","kind":"opencode","label":"Work","addedAt":0}]"#
        defaults.set(Data(saved.utf8), forKey: AccountStore.storageKey)

        let account = try XCTUnwrap(AccountStore(defaults: defaults, vault: InMemoryCredentialVault()).accounts.first)

        XCTAssertEqual(account.kind, .opencodeGo)
        XCTAssertEqual(account.label, "Work")
        XCTAssertEqual(account.cardID, "opencode@8ad3b217")
        XCTAssertEqual(account.kind.displayName, "OpenCode")
    }

    func testAnAPIKeyAccountShowsItsUsageAndNoPlan() async throws {
        let (runtime, http) = try runtime(.apiKey("key")) { _ in Self.json(Self.usage) }

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.displayName, "OpenCode")
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly"])
        XCTAssertEqual(runtime.widgetDescriptors.map(\.id).first, "\(runtime.account.cardID).session")
        XCTAssertEqual(http.requests.map(\.url), [OpenCodeUsageClient.usageURL])
    }

    func testASignedInAccountShowsThePlanGoStatusNames() async throws {
        let (runtime, http) = try runtime(Self.signIn) { request in
            request.url == OpenCodeUsageClient.goStatusURL ? Self.json(#"{"product":"go-plus","access":{}}"#) : Self.json(Self.usage)
        }

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.plan, "Go Plus")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly"])
        XCTAssertEqual(Set(http.requests.map(\.url)), [OpenCodeUsageClient.usageURL, OpenCodeUsageClient.goStatusURL])
        XCTAssertEqual(Set(http.requests.map { $0.headers["Authorization"] }), ["Bearer console"])
        XCTAssertEqual(http.requests.first { $0.url == OpenCodeUsageClient.usageURL }?.headers["x-opencode-org-id"], "wrk_01")
        XCTAssertEqual(http.requests.first { $0.url == OpenCodeUsageClient.goStatusURL }?.headers["x-org-id"], "wrk_01")
    }

    func testAFailedPlanReadKeepsTheUsageAndDropsThePlan() async throws {
        let clock = Clock()
        let (runtime, _) = try runtime(Self.signIn, now: { clock.now }) { request in
            guard request.url == OpenCodeUsageClient.goStatusURL else { return Self.json(Self.usage) }
            return clock.planReads == 0 ? Self.json(#"{"product":"go"}"#) : Self.json("{}", status: 500)
        }
        let first = try await runtime.refresh().get()
        XCTAssertEqual(first.plan, "Go")

        clock.planReads = 1
        clock.now += RefreshSetting.secondaryReadInterval
        let snapshot = try await runtime.refresh().get()

        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly"])
    }

    func testAnAPIKeyAccountSignsInAgainAsTheSameAccount() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let account = accounts.add(kind: .opencodeGo, label: "Work", credential: .apiKey("key"))
        _ = accounts.add(kind: .opencodeGo, label: "Personal", credential: .apiKey("other-key"))
        let http = RoutingHTTPClient { request in
            request.url == OpenCodeUsageClient.goStatusURL ? Self.json(#"{"product":"go"}"#) : Self.json(Self.usage)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let session = "\(account.cardID).session"
        XCTAssertTrue(container.layout.setMetric(session, pinned: true))
        let order = accounts.accounts.map(\.id)
        let signedInWithKey = await container.signsInWithKey(account.cardID)
        XCTAssertTrue(signedInWithKey)
        let signIn = AccountCredential.oauth(.init(accessToken: "console", extras: [OAuthTokens.identityKey: "opencode:usr_01:wrk_01", OpenCodeLogin.orgKey: "wrk_01"]))

        try await container.replaceCredential(signIn, for: account.cardID)

        XCTAssertEqual(try vault.load(account.id), signIn)
        XCTAssertEqual(accounts.accounts.map(\.id), order)
        XCTAssertEqual(accounts.account(cardID: account.cardID)?.label, "Work")
        XCTAssertTrue(container.layout.isMetricPinned(session))
        let stillOnKey = await container.signsInWithKey(account.cardID)
        XCTAssertFalse(stillOnKey)
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var planReads = 0
}
