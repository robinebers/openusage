import XCTest
@testable import OpenUsage

/// The CLI-facing claim runner: outcome→status mapping, the printed JSON document, and warning
/// passthrough from the post-claim refresh hook — through the same stub HTTP client as the service's
/// own tests (the real endpoint is never touched).
@MainActor
final class CodexResetClaimRunnerTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let redeemID = "11111111-2222-3333-4444-555555555555"

    private func makeRunner(
        listBody: Data? = nil,
        consumeCode: String = "reset",
        warnings: CodexResetClaimRunner.WarningSink = CodexResetClaimRunner.WarningSink(),
        refreshAfterClaim: @escaping () async -> Void = {}
    ) -> CodexResetClaimRunner {
        let list = listBody ?? Data("""
        {"credits": [{"id": "RateLimitResetCredit_target", "status": "available",
                      "expires_at": "\(OpenUsageISO8601.string(from: Self.expiry))"}]}
        """.utf8)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: list)
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: Data(#"{"code": "\#(consumeCode)"}"#.utf8))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("token-123", "acct-456")] },
            refreshAfterClaim: refreshAfterClaim
        )
        return CodexResetClaimRunner(service: service, warnings: warnings, makeRedeemRequestID: { Self.redeemID })
    }

    func testClaimedResultPrintsCompactSortedJSON() async {
        let result = await makeRunner().claimNextAvailableCredit()

        XCTAssertEqual(result.status, .claimed)
        XCTAssertTrue(result.warnings.isEmpty)
        let expiryString = OpenUsageISO8601.string(from: Self.expiry)
        XCTAssertEqual(
            String(decoding: result.data, as: UTF8.self),
            #"{"creditExpiresAt":"\#(expiryString)","provider":"codex","redeemRequestID":"\#(Self.redeemID)","schema":"openusage.claim.v1","status":"claimed"}"#
        )
    }

    func testNoCreditResultOmitsExpiryAndKeepsSchema() async {
        let result = await makeRunner(listBody: Data(#"{"credits": []}"#.utf8)).claimNextAvailableCredit()

        XCTAssertEqual(result.status, .noCredit)
        XCTAssertEqual(
            String(decoding: result.data, as: UTF8.self),
            #"{"provider":"codex","redeemRequestID":"\#(Self.redeemID)","schema":"openusage.claim.v1","status":"no_credit"}"#
        )
    }

    func testNothingToResetMapsToItsOwnStatus() async {
        let result = await makeRunner(consumeCode: "nothing_to_reset").claimNextAvailableCredit()
        XCTAssertEqual(result.status, .nothingToReset)
        XCTAssertTrue(String(decoding: result.data, as: UTF8.self).contains(#""status":"nothing_to_reset""#))
    }

    func testRefreshHookWarningsSurfaceOnTheResult() async {
        let warnings = CodexResetClaimRunner.WarningSink()
        let runner = makeRunner(warnings: warnings, refreshAfterClaim: { @MainActor in
            warnings.messages.append("post-claim refresh failed: boom")
        })

        let result = await runner.claimNextAvailableCredit()

        XCTAssertEqual(result.status, .claimed)
        XCTAssertEqual(result.warnings, ["post-claim refresh failed: boom"])
    }
}
