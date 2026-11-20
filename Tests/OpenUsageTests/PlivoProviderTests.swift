import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class PlivoProviderTests: XCTestCase {
    /// The Account object as Plivo's API reference documents it.
    private nonisolated static let documented = #"{"account_type":"standard","address":"Wayne Enterprises Inc.","api_id":"150892a0-922a-11e7-b6f4-061564b78b75","auth_id":"MA2025RK4E639VJFZAGV","auto_recharge":false,"billing_mode":"prepaid","cash_credits":"1.80900","city":"Gotham","name":"Bruce Wayne","resource_uri":"/v1/Account/MA2025RK4E639VJFZAGV/","state":"NY","timezone":"America/New_York"}"#

    private func runtime(
        key: String = "MA2025RK4E639VJFZAGV:plivo-token",
        _ answer: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) throws -> (AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .plivo, label: "Plivo")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey(key), for: account.id)
        let http = RoutingHTTPClient { answer($0) }
        return (AccountProviderRuntime(account: account, vault: vault, http: http), http)
    }

    func testCreditsAreTheAccountsCashCreditsInDollars() async throws {
        let (runtime, http) = try runtime { _ in .json(Self.documented) }

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.plan, "Prepaid")
        XCTAssertEqual(snapshot.lines, [.values(label: "Credits", values: [MetricValue(number: 1.809, kind: .dollars)])])
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.plivo.com/v1/Account/MA2025RK4E639VJFZAGV/")
        XCTAssertEqual(request.headers["Authorization"], "Basic " + Data("MA2025RK4E639VJFZAGV:plivo-token".utf8).base64EncodedString())
        XCTAssertEqual(runtime.widgetDescriptors.map(\.key), ["credits"])
    }

    func testTheKeySplitsIntoAuthIDAndTokenAtTheFirstColon() {
        XCTAssertEqual(PlivoCredentials(key: " MA123 : tok:en "), PlivoCredentials(key: "MA123:tok:en"))
        XCTAssertEqual(PlivoCredentials(key: "MA123:tok:en")?.authID, "MA123")
        XCTAssertEqual(PlivoCredentials(key: "MA123:tok:en")?.authToken, "tok:en")
        for key in ["MA123", "MA123:", ":token", "MA/../x:token", "MA 123:token", ""] {
            XCTAssertNil(PlivoCredentials(key: key), key)
        }
    }

    func testAKeyWithoutAuthIDAndTokenSaysHowToEnterItAndSendsNothing() async throws {
        let (runtime, http) = try runtime(key: "plivo-token") { _ in .json(Self.documented) }

        let failure = await runtime.refresh()

        XCTAssertEqual(failure.failure?.message, "Plivo needs the Auth ID and Auth Token as AUTH_ID:AUTH_TOKEN. Replace it on the account's page.")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testARefusedAuthTokenAsksToReplaceIt() async throws {
        let (runtime, _) = try runtime { _ in .json(#"{"api_id":"x","error":"Authentication failed"}"#, status: 401) }

        let failure = await runtime.refresh()

        XCTAssertEqual(failure.failure?.message, "Plivo rejected the Auth ID and Token. Replace it on the account's page.")
    }

    func testTheAddSheetExplainsAKeyItCannotUse() async throws {
        let http = RoutingHTTPClient { _ in .json(Self.documented) }
        let input = AsyncStream<String> { $0.yield("plivo-token"); $0.finish() }

        do {
            _ = try await APIKeyLogin(kind: .plivo, http: http).login(prompt: { _ in }, pastedCode: input)
            XCTFail("a key without an Auth ID is refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Plivo needs the Auth ID and Auth Token as AUTH_ID:AUTH_TOKEN.")
        }
    }

    func testAnAccountWithoutCashCreditsIsAnInvalidResponse() async throws {
        let (runtime, _) = try runtime { _ in .json(#"{"account_type":"standard","billing_mode":"prepaid"}"#) }

        let failure = await runtime.refresh()

        XCTAssertEqual(failure.failure?.message, ProviderError.invalidResponse.localizedDescription)
    }
}
