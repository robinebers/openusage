import Foundation
import XCTest
@testable import OpenUsage

/// OpenCode is named "OpenCode" with a "Go" plan tag, while every stored identifier keeps `opencode`.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
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

    func testRefreshTagsTheAccountWithTheGoPlan() async throws {
        let account = Account(kind: .opencodeGo, label: "OpenCode")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let body = #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-07-12T13:30:00Z"},"weekly":{"percent":8,"resetsAt":"2026-07-13T00:00:00Z"},"monthly":{"percent":40,"resetsAt":"2026-08-04T11:18:32Z"}}}"#
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)) }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = await runtime.refresh()

        XCTAssertEqual(snapshot.displayName, "OpenCode")
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly"])
        XCTAssertEqual(runtime.widgetDescriptors.map(\.id).first, "\(account.cardID).session")
    }
}
