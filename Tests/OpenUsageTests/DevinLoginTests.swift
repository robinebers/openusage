import Foundation
import XCTest
@testable import OpenUsage

private let userStatus = #"""
{"userStatus":{"email":"rob@example.com","teamId":"devin-team$account-1",
 "planStatus":{"planInfo":{"planName":"Max"},"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":25}}}
"""#
private let refused = #"{"code":"unauthenticated","message":"invalid token"}"#
private let selfServeStatusURL = "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
private let defaultStatusURL = "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
private let registerURL = "https://register.windsurf.com/exa.seat_management_pb.SeatManagementService/RegisterUser"

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
            let http = RoutingHTTPClient { _ in .json("{}", status: 500) }
            _ = try? await DevinLogin(http: http).login(prompt: { prompt.value = $0 }, pastedCode: closedInput)

            guard case .browserToken(let url) = prompt.value else { return XCTFail("expected the token page, got \(String(describing: prompt.value))") }
            let page = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (page.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual("\(page.scheme ?? "")://\(page.host ?? "")\(page.path)", "https://windsurf.com/windsurf/signin")
            XCTAssertEqual(query["response_type"], "token")
            XCTAssertEqual(query["client_id"], "3GUryQ7ldAeKEuD2obYnppsnmj58eP5u")
            XCTAssertEqual(query["redirect_uri"], "show-auth-token")
            XCTAssertEqual(query["prompt"], "login")
            XCTAssertEqual(query["redirect_parameters_type"], "query")
            states.append(try XCTUnwrap(query["state"]))
            XCTAssertTrue(http.requests.isEmpty, "nothing is sent before a token is pasted")
        }
        XCTAssertNotEqual(states[0], states[1], "every sign-in sends its own state")
    }

    func testAPastedTokenIsTradedForTheAPIKeyOnTheServerWindsurfNames() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.absoluteString {
            case registerURL:
                .json(#"{"api_key":"devin-session-token$abc","name":"Rob","api_server_url":"https://server.self-serve.windsurf.com"}"#)
            case selfServeStatusURL:
                .json(userStatus)
            default:
                .json("{}", status: 404)
            }
        }

        let result = try await signIn(pasting: " one-time-token\n", http: http)

        XCTAssertEqual(result.label, "rob@example.com")
        XCTAssertEqual(result.credential, .oauth(OAuthTokens(accessToken: "devin-session-token$abc", extras: [
            OAuthTokens.identityKey: "devin:rob@example.com/devin-team$account-1",
            DevinUsageClient.apiServerURLKey: "https://server.self-serve.windsurf.com"
        ])))
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [registerURL, selfServeStatusURL])
        XCTAssertEqual(jsonBody(http.requests.first) as? [String: String], ["firebase_id_token": "one-time-token"])
        XCTAssertEqual((jsonBody(http.requests.last)?["metadata"] as? [String: Any])?["apiKey"] as? String, "devin-session-token$abc")
    }

    func testAnAPIKeyPastedInsteadOfATokenSignsInOnTheDefaultServer() async throws {
        let http = RoutingHTTPClient { request in
            request.url.host() == "register.windsurf.com"
                ? .json(refused, status: 401)
                : .json(#"{"userStatus":{"email":"rob@example.com"}}"#)
        }

        let result = try await signIn(pasting: "sk-ws-01-pasted", http: http)

        XCTAssertEqual(result.credential, .oauth(OAuthTokens(
            accessToken: "sk-ws-01-pasted",
            extras: [OAuthTokens.identityKey: "devin:rob@example.com"]
        )))
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [registerURL, defaultStatusURL])
    }

    /// #1684: the retired api.codeium.com/register_user/ answered every request with 404, which ended a
    /// pasted Devin session token's sign-in. A session token is the API key, so it skips RegisterUser.
    func testAPastedDevinSessionTokenSignsInWithoutRegisterUser() async throws {
        let http = RoutingHTTPClient { request in
            request.url.absoluteString == defaultStatusURL
                ? .json(#"{"userStatus":{"email":"rob@example.com"}}"#)
                : .json("404 page not found", status: 404)
        }

        let result = try await signIn(pasting: " devin-session-token$pasted\n", http: http)

        XCTAssertEqual(result.label, "rob@example.com")
        XCTAssertEqual(result.credential, .oauth(OAuthTokens(
            accessToken: "devin-session-token$pasted",
            extras: [OAuthTokens.identityKey: "devin:rob@example.com"]
        )))
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [defaultStatusURL])
    }

    func testADevinSessionTokenDevinRefusesSaysSo() async throws {
        let http = RoutingHTTPClient { _ in .json(refused, status: 401) }

        do {
            _ = try await signIn(pasting: "devin-session-token$revoked", http: http)
            XCTFail("a revoked session token signed in")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Devin rejected that session token. Click Try Again and sign in on the page to get a new token.")
        }
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [defaultStatusURL])
    }

    func testATokenWindsurfRefusesAsksForANewOne() async throws {
        let http = RoutingHTTPClient { _ in .json(refused, status: 401) }

        do {
            _ = try await signIn(pasting: "expired-token", http: http)
            XCTFail("an expired token signed in")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Windsurf rejected that token. A token works for 5 minutes, so click Try Again to get a new one.")
        }
    }

    func testAnAPIServerOutsideHTTPSNeverReceivesTheKey() async throws {
        let http = RoutingHTTPClient { _ in .json(#"{"api_key":"devin-session-token$abc","api_server_url":"http://server.example"}"#) }

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
        let http = RoutingHTTPClient { _ in .json(userStatus) }

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
