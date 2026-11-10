import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AmpProviderTests: XCTestCase {
    /// A real `userDisplayBalanceInfo` answer for a Megawatt account, with the email and username redacted.
    private nonisolated static let megawatt = #"{"ok":true,"result":{"displayText":"Signed in as amp@example.com (example)\nAmp Megawatt Tier: agent usage $19.98 of $20.00 remaining (100%), orb usage 737.6h of 750h a1.small orb hours remaining (98%) - period 2026-11-09 to 2026-12-09, ends in 29 days\nIndividual credits: $57.45 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings"}}"#
    private static let periodStart = Date(timeIntervalSince1970: 1_794_182_400)
    private static let periodEnd = Date(timeIntervalSince1970: 1_796_774_400)
    private static let now = Date(timeIntervalSince1970: 1_794_290_000)

    private nonisolated static func balance(_ lines: String) -> HTTPResponse {
        .json(#"{"ok":true,"result":{"displayText":"Signed in as amp@example.com (example)\n\#(lines)"}}"#)
    }

    private func runtime(
        _ tokens: OAuthTokens = OAuthTokens(accessToken: "amp-access"),
        answer: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) throws -> (AccountProviderRuntime, InMemoryCredentialVault, RoutingHTTPClient, Account) {
        let account = Account(kind: .amp, label: "amp@example.com")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(tokens), for: account.id)
        let http = RoutingHTTPClient { answer($0) }
        return (AccountProviderRuntime(account: account, vault: vault, http: http, now: { Self.now }), vault, http, account)
    }

    func testATierAccountShowsAgentUsageOrbHoursAndCreditsAsAmpReportsThem() async throws {
        let (runtime, _, http, _) = try runtime { _ in .json(Self.megawatt) }

        let snapshot = try await runtime.refresh().get()

        let periodMs = Int(Self.periodEnd.timeIntervalSince(Self.periodStart) * 1000)
        XCTAssertEqual(snapshot.plan, "Megawatt")
        XCTAssertEqual(snapshot.lines, [
            .progress(label: "Agent Usage", used: 0.02, limit: 20, format: .dollars, resetsAt: Self.periodEnd, periodDurationMs: periodMs),
            .progress(label: "Orb Hours", used: 12.4, limit: 750, format: .count(suffix: "hours"), resetsAt: Self.periodEnd, periodDurationMs: periodMs),
            .values(label: "Individual Credits", values: [MetricValue(number: 57.45, kind: .dollars)])
        ])
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, AmpUsageClient.balanceURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer amp-access")
        XCTAssertEqual(request.body.map { String(decoding: $0, as: UTF8.self) }, #"{"method":"userDisplayBalanceInfo","params":{}}"#)
        XCTAssertEqual(runtime.widgetDescriptors.map(\.key), ["agent", "orbHours", "free", "credits"])
    }

    func testAFreeAccountShowsItsDailyAllowanceAndAnEmptyCreditBalance() async throws {
        let (runtime, _, _, _) = try runtime { _ in
            Self.balance(#"Amp Free: 61% remaining today (resets daily) - https://ampcode.com/settings#amp-free\nIndividual credits: $0 remaining - https://ampcode.com/settings"#)
        }

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.plan, "Free")
        XCTAssertEqual(snapshot.lines, [
            .percent("Amp Free", 39, periodMs: MetricPeriod.dayMs),
            .values(label: "Individual Credits", values: [MetricValue(number: 0, kind: .dollars)])
        ], "a balance shows even at $0")
    }

    func testAmpFreeInDollarsReadsAsTheShareSpent() async throws {
        let (runtime, _, _, _) = try runtime { _ in
            Self.balance(#"Amp Free: $7.50/$10.00 remaining (replenishes +$0.42/hour) - https://ampcode.com/settings#amp-free"#)
        }

        let lines = try await runtime.refresh().get().lines

        XCTAssertEqual(lines, [.percent("Amp Free", 25, periodMs: MetricPeriod.dayMs)], "no reset time is made up from the replenish rate")
    }

    func testTextWithNoAllowanceIsAnInvalidResponse() async throws {
        let (runtime, _, _, _) = try runtime { _ in Self.balance("Amp is down for maintenance") }

        let failure = await runtime.refresh()

        XCTAssertEqual(failure.failure?.message, ProviderError.invalidResponse.localizedDescription)
    }

    func testAnExpiringTokenIsRenewedBeforeTheReadAndTheRotatedRefreshTokenIsKept() async throws {
        let renewed = Self.jwt(#"{"sub":"user_1","exp":\#(Int(Self.now.timeIntervalSince1970) + 300)}"#)
        let expiring = OAuthTokens(accessToken: "amp-old", refreshToken: "refresh-1", expiresAt: Self.now.addingTimeInterval(60))
        let (runtime, vault, http, account) = try runtime(expiring) { request in
            request.url == AmpLogin.authenticateURL
                ? .json(#"{"user":{"id":"user_1"},"access_token":"\#(renewed)","refresh_token":"refresh-2"}"#)
                : .json(Self.megawatt)
        }

        _ = try await runtime.refresh().get()

        let renewal = try XCTUnwrap(http.requests.first)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(renewal.body)) as? [String: String])
        XCTAssertEqual(renewal.url, AmpLogin.authenticateURL)
        XCTAssertEqual(fields, ["client_id": AmpLogin.clientID, "grant_type": "refresh_token", "refresh_token": "refresh-1"])
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer \(renewed)")
        guard case .oauth(let stored)? = try vault.load(account.id) else { return XCTFail("no stored sign-in") }
        XCTAssertEqual(stored.refreshToken, "refresh-2", "WorkOS rotates the refresh token on every renewal")
        XCTAssertEqual(stored.expiresAt, Self.now.addingTimeInterval(300))
    }

    func testARefusedRenewalAsksToSignInAgain() async throws {
        let expiring = OAuthTokens(accessToken: "amp-old", refreshToken: "refresh-1", expiresAt: Self.now.addingTimeInterval(-1))
        let (runtime, _, _, _) = try runtime(expiring) { _ in
            .json(#"{"error":"invalid_grant","error_description":"Invalid refresh token."}"#, status: 400)
        }

        let failure = await runtime.refresh()

        XCTAssertEqual(failure.failure?.message, ProviderError.signInExpired(.amp).localizedDescription)
        XCTAssertEqual(failure.failure?.kind, .refused)
    }

    private static func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).signature"
    }
}
