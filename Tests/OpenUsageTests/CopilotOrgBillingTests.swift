import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CopilotOrgBillingTests: XCTestCase {
    nonisolated private static let orgBody = #"""
    {"timePeriod":{"year":2025},"organization":"GitHub","usageItems":[{"product":"Copilot","sku":"Copilot AI Credits",
     "model":"GPT-5","unitType":"credits","pricePerUnit":0.01,"grossQuantity":100,"grossAmount":1.0,"discountQuantity":0,
     "discountAmount":0.0,"netQuantity":100,"netAmount":1.0}]}
    """#
    nonisolated private static let noCopilotBody = #"{"usageItems":[{"product":"Actions","grossQuantity":500,"netAmount":4.0}]}"#
    private static let orgLines: [MetricLine] = [
        .values(label: "Org Credits", values: [MetricValue(number: 100, kind: .count, label: "credits")]),
        .values(label: "Org Spend", values: [MetricValue(number: 1, kind: .dollars)])
    ]

    func testOrgUsageCountsCopilotCreditsAndSpendOnly() {
        XCTAssertEqual(CopilotOrgBillingMapper.usageLines(Self.ok(Self.orgBody)), Self.orgLines)
        XCTAssertEqual(CopilotOrgBillingMapper.usageLines(Self.ok(Self.noCopilotBody)), [
            .values(label: "Org Credits", values: [MetricValue(number: 0, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: 0, kind: .dollars)])
        ], "an org with no Copilot usage yet shows zero")
    }

    func testAnInvalidOrgReportMapsToNothing() {
        for body in ["not json", "{}", #"{"usageItems":{"product":"Copilot"}}"#, #"{"usageItems":[{"product":"Copilot","grossQuantity":100}]}"#] {
            XCTAssertNil(CopilotOrgBillingMapper.usageLines(Self.ok(body)), body)
        }
    }

    func testAddingAnOrganizationChecksTheTokenWithOneRead() async throws {
        let http = RoutingHTTPClient { request in
            switch request.headers["Authorization"] {
            case "Bearer good": Self.ok(Self.orgBody)
            case "Bearer garbage": Self.ok("<html>")
            case "Bearer elsewhere": Self.response(404, "{}")
            default: Self.response(403, "{}")
            }
        }

        let added = try await login("good", http: http)
        XCTAssertEqual(added.label, "acme")
        XCTAssertEqual(added.credential, .apiKey("good"))
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://api.github.com/organizations/acme/settings/billing/ai_credit/usage")
        XCTAssertEqual(request.headers["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertEqual(request.headers["Accept"], "application/vnd.github+json")

        for (token, message) in [
            ("refused", "GitHub rejected the token."),
            ("elsewhere", "GitHub has no organization “acme” this token can read."),
            ("garbage", ProviderError.invalidResponse.localizedDescription)
        ] {
            do {
                _ = try await login(token, http: http)
                XCTFail("\(token) was accepted")
            } catch {
                XCTAssertEqual(error.localizedDescription, message, token)
            }
        }
    }

    func testAnOrganizationAccountShowsItsCreditsAndSpend() async throws {
        let account = Account(kind: .copilot, label: "acme", organization: "acme")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("good"), for: account.id)
        let http = RoutingHTTPClient { _ in Self.ok(Self.orgBody) }
        let snapshot = try await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().get()

        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines, Self.orgLines)
        XCTAssertEqual(http.requests.map(\.url), [CopilotUsageClient.organizationUsageURL("acme")])
    }

    func testReplacingTheTokenKeepsTheOrganizationAndAcceptsATokenAnotherOrganizationUses() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let http = RoutingHTTPClient { request in
            request.headers["Authorization"] == "Bearer refused" ? Self.response(403, "{}") : Self.ok(Self.orgBody)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let acme = accounts.add(kind: .copilot, label: "acme", organization: "acme", credential: .apiKey("old"))
        let beta = accounts.add(kind: .copilot, label: "beta", organization: "beta", credential: .apiKey("classic"))

        do {
            try await container.replaceKey("refused", for: acme.cardID)
            XCTFail("a refused token was saved")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub rejected the token.")
        }
        XCTAssertEqual(try vault.load(acme.id), .apiKey("old"))

        try await container.replaceKey(" classic ", for: acme.cardID)
        XCTAssertEqual(try vault.load(acme.id), .apiKey("classic"))
        XCTAssertEqual(try vault.load(beta.id), .apiKey("classic"))
        XCTAssertEqual(accounts.accounts.map(\.organization), ["acme", "beta"])
        XCTAssertEqual(accounts.accounts.map(\.label), ["acme", "beta"])
        XCTAssertEqual(container.dataStore.snapshots[acme.cardID]?.lines, Self.orgLines)
    }

    private func login(_ token: String, http: RoutingHTTPClient) async throws -> (label: String, credential: AccountCredential) {
        let (input, continuation) = AsyncStream.makeStream(of: String.self)
        continuation.yield(token)
        continuation.finish()
        return try await CopilotOrganizationLogin(organization: "acme", http: http).login(prompt: { _ in }, pastedCode: input)
    }

    nonisolated private static func ok(_ body: String) -> HTTPResponse {
        response(200, body)
    }

    nonisolated private static func response(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
    }
}
