import CryptoKit
import Foundation
import XCTest
@testable import OpenUsage

private let userStatus = #"""
{"userStatus":{"email":"rob@example.com","teamId":"devin-team$account-1",
 "planStatus":{"planInfo":{"planName":"Max"},"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":25}}}
"""#
private let tokenURL = "https://api.devin.ai/auth/cli/token"
private let defaultStatusURL = "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
private let selfServeStatusURL = "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"

private func jsonBody(_ request: HTTPRequest?) -> [String: Any]? {
    request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

final class DevinLoginTests: XCTestCase {
    /// #1684: the sign-in page OpenUsage opened never handed anything back. Devin's CLI signs in with PKCE on
    /// app.devin.ai and a 127.0.0.1 callback, then trades the code for a session token at api.devin.ai.
    func testSignInRunsTheDevinCLIFlowAndReadsUsageWithTheSessionToken() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url.absoluteString {
            case tokenURL: .json(#"{"token":"eyJ.session.jwt","webapp_host":"app.devin.ai"}"#)
            case defaultStatusURL: .json(userStatus)
            default: .json("{}", status: 404)
            }
        }
        let prompt = TestSwitch<LoginPrompt?>(nil)
        let callback = TestSwitch<Int?>(nil)

        let result = try await DevinLogin(http: http).login(prompt: { value in
            prompt.value = value
            if case .browser(let url, _) = value { callback.value = await completeLoopbackCallback(url) }
        }, pastedCode: AsyncStream { $0.finish() })

        guard case .browser(let authorizeURL, acceptsPastedCode: false) = prompt.value else {
            return XCTFail("expected a browser sign-in with nothing to paste, got \(String(describing: prompt.value))")
        }
        let page = try XCTUnwrap(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (page.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual("\(page.scheme ?? "")://\(page.host ?? "")\(page.path)", "https://app.devin.ai/auth/cli/continue")
        let redirect = try XCTUnwrap(query["redirect_uri"].flatMap(URLComponents.init(string:)))
        XCTAssertEqual(redirect.host, "127.0.0.1", "Devin refuses a localhost redirect")
        XCTAssertEqual(redirect.path, "/callback", "Devin refuses any other callback path")
        XCTAssertEqual(query["prompt"], "select_account")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(callback.value, 200)

        XCTAssertEqual(http.requests.map(\.url.absoluteString), [tokenURL, defaultStatusURL])
        let exchange = try XCTUnwrap(jsonBody(http.requests.first) as? [String: String])
        XCTAssertEqual(exchange["code"], "fake-authorization-code")
        let verifier = try XCTUnwrap(exchange["code_verifier"])
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(query["code_challenge"], challenge)
        XCTAssertEqual((jsonBody(http.requests.last)?["metadata"] as? [String: Any])?["apiKey"] as? String, "devin-session-token$eyJ.session.jwt")

        XCTAssertEqual(result.label, "rob@example.com")
        XCTAssertEqual(result.credential, .oauth(OAuthTokens(
            accessToken: "devin-session-token$eyJ.session.jwt",
            extras: [OAuthTokens.identityKey: "devin:rob@example.com/devin-team$account-1"]
        )))
    }

    func testARefusedCodeExchangeSaysSoAndReadsNothing() async throws {
        let http = RoutingHTTPClient { _ in .json(#"{"detail":"invalid code"}"#, status: 401) }

        do {
            _ = try await DevinLogin(http: http).login(prompt: { value in
                if case .browser(let url, _) = value { _ = await completeLoopbackCallback(url) }
            }, pastedCode: AsyncStream { $0.finish() })
            XCTFail("signed in with a refused code")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Devin didn’t accept the sign-in. Click Try Again to sign in again.")
        }
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [tokenURL])
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
}
