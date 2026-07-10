import XCTest
@testable import OpenUsage

@MainActor
final class CodexProviderTests: XCTestCase {
    func testNoUsageDataBadgeIsDroppedWhenLocalLogsHaveSpend() async throws {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        // The live usage API returns nothing mappable (empty body -> no metric lines)...
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(timestamp: "2026-02-20T14:00:00.000Z", model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: "2026-02-20T14:01:00.000Z",
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            now: { now },
            pricing: {
                // 150 tokens -> $0.25 at these fixture rates: (100 x 1000 + 50 x 3000) / 1M.
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                        inputPerMillion: 1000, outputPerMillion: 3000,
                        cacheWritePerMillion: 1000, cacheReadPerMillion: 100
                    )]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        let snapshot = await provider.refresh()

        // ...but local scanned spend exists, so the snapshot shows the spend lines and NOT the
        // "No usage data" badge. Regression: the mapper used to append the badge *before* the spend
        // lines, leaving a contradictory badge-plus-spend snapshot.
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertFalse(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }
}
