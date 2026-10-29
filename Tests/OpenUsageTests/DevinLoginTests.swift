import Foundation
import XCTest
@testable import OpenUsage

private let userStatus = #"""
{"userStatus":{"email":"rob@example.com","teamId":"devin-team$account-1",
 "planStatus":{"planInfo":{"planName":"Max"},"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":25}}}
"""#
private let refused = #"{"code":"unauthenticated","message":"invalid token"}"#
private let selfServeStatusURL = "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"

private func response(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
}

private func jsonBody(_ request: HTTPRequest?) -> [String: Any]? {
    request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

final class DevinLoginTests: XCTestCase {
    func testTheBrowserOpensWindsurfsTokenPageWithAFreshState() async throws {
        var states: [String] = []
        for _ in 0..<2 {
            let prompt = TestSwitch<LoginPrompt?>(nil)
            let (closedInput, input) = AsyncStream.makeStream(of: String.self)
            input.finish()
            let http = RoutingHTTPClient { _ in response("{}", status: 500) }
            _ = try? await DevinLogin(http: http).login(prompt: { prompt.value = $0 }, pastedCode: closedInput)

            guard case .browserToken(let url) = prompt.value else { return XCTFail("expected the token page, got \(String(describing: prompt.value))") }
            let page = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (page.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual("\(page.scheme ?? "")://\(page.host ?? "")\(page.path)", "https://windsurf.com/profile")
            XCTAssertEqual(query["response_type"], "token")
            XCTAssertEqual(query["redirect_uri"], "show-auth-token")
            XCTAssertEqual(query["scope"], "openid profile email")
            XCTAssertEqual(query["redirect_parameters_type"], "query")
            states.append(try XCTUnwrap(query["state"]))
            XCTAssertTrue(http.requests.isEmpty, "nothing is sent before a token is pasted")
        }
        XCTAssertNotEqual(states[0], states[1], "every sign-in sends its own state")
    }

    func testAPastedTokenIsTradedForTheAPIKeyOnTheServerWindsurfNames() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.absoluteString {
            case "https://api.codeium.com/register_user/":
                response(#"{"api_key":"devin-session-token$abc","name":"Rob","api_server_url":"https://server.self-serve.windsurf.com"}"#)
            case selfServeStatusURL:
                response(userStatus)
            default:
                response("{}", status: 404)
            }
        }

        let result = try await signIn(pasting: " one-time-token\n", http: http)

        XCTAssertEqual(result.label, "rob@example.com")
        XCTAssertEqual(result.credential, .oauth(OAuthTokens(accessToken: "devin-session-token$abc", extras: [
            OAuthTokens.identityKey: "devin:rob@example.com/devin-team$account-1",
            DevinUsageClient.apiServerURLKey: "https://server.self-serve.windsurf.com"
        ])))
        XCTAssertEqual(http.requests.map(\.url.absoluteString), ["https://api.codeium.com/register_user/", selfServeStatusURL])
        XCTAssertEqual(jsonBody(http.requests.first) as? [String: String], ["firebase_id_token": "one-time-token"])
        XCTAssertEqual((jsonBody(http.requests.last)?["metadata"] as? [String: Any])?["apiKey"] as? String, "devin-session-token$abc")
    }

    func testAnAPIKeyPastedInsteadOfATokenSignsInOnTheDefaultServer() async throws {
        let http = RoutingHTTPClient { request in
            request.url.host() == "api.codeium.com"
                ? response(refused, status: 401)
                : response(#"{"userStatus":{"email":"rob@example.com"}}"#)
        }

        let result = try await signIn(pasting: "devin-session-token$pasted", http: http)

        XCTAssertEqual(result.credential, .oauth(OAuthTokens(
            accessToken: "devin-session-token$pasted",
            extras: [OAuthTokens.identityKey: "devin:rob@example.com"]
        )))
        XCTAssertEqual(
            http.requests.last?.url.absoluteString,
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        )
    }

    func testATokenWindsurfRefusesAsksForANewOne() async throws {
        let http = RoutingHTTPClient { _ in response(refused, status: 401) }

        do {
            _ = try await signIn(pasting: "expired-token", http: http)
            XCTFail("an expired token signed in")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Windsurf rejected that token. A token works for 5 minutes, so click Try Again to get a new one.")
        }
    }

    func testAnAPIServerOutsideHTTPSNeverReceivesTheKey() async throws {
        let http = RoutingHTTPClient { _ in response(#"{"api_key":"devin-session-token$abc","api_server_url":"http://server.example"}"#) }

        do {
            _ = try await signIn(pasting: "one-time-token", http: http)
            XCTFail("signed in against a plain-HTTP server")
        } catch {
            XCTAssertEqual(error.localizedDescription, LoginError.invalidResponse.localizedDescription)
        }
        XCTAssertEqual(http.requests.count, 1)
    }

    @MainActor
    func testARefreshReadsUsageFromTheAccountsOwnServer() async throws {
        let account = Account(kind: .devin, label: "rob@example.com")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(
            accessToken: "devin-session-token$abc",
            extras: [DevinUsageClient.apiServerURLKey: "https://server.self-serve.windsurf.com"]
        )), for: account.id)
        let http = RoutingHTTPClient { _ in response(userStatus) }

        let snapshot = try await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().get()

        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.lines, [
            .percent("Daily quota", 20, periodMs: MetricPeriod.dayMs),
            .percent("Weekly quota", 75, periodMs: MetricPeriod.weekMs)
        ])
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [selfServeStatusURL])
    }

    private func signIn(pasting value: String, http: RoutingHTTPClient) async throws -> (label: String, credential: AccountCredential) {
        let (pasted, input) = AsyncStream.makeStream(of: String.self)
        input.yield(value)
        input.finish()
        return try await DevinLogin(http: http).login(prompt: { _ in }, pastedCode: pasted)
    }
}
