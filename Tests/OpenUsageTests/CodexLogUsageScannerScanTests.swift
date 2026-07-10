import XCTest
@testable import OpenUsage

/// End-to-end session discovery, caching, and bundled-pricing coverage for the Codex log scanner.
extension CodexLogUsageScannerTests {
    // MARK: - End-to-end scan

    func testScanReadsSessionsAndArchivedSessions() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/2026/05/rollout-a.jsonl": [
                CodexLogFixture.turnContext(timestamp: day, model: "gpt-5.2"),
                CodexLogFixture.tokenCount(timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50))
            ].joined(separator: "\n"),
            "archived_sessions/rollout-b.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 30, output: 20), model: "gpt-5.2"
            )
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: CodexLogUsageScannerTestFixtures.fixedRates())

        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
    }

    func testScanPrefersActiveSessionsCopyOverArchivedDuplicate() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let content = CodexLogFixture.tokenCount(
            timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
        )
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": content,
            "archived_sessions/rollout-a.jsonl": content
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: CodexLogUsageScannerTestFixtures.fixedRates())

        // Same relative path in both dirs = the same session archived; identical events dedupe
        // anyway, but the discovery-level rule keeps it to one parse.
        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
    }

    func testScanReturnsNilWithoutCodexHome() async {
        let scanner = CodexLogFixture.scanner(home: nil)
        let scan = await scanner.scan(pricing: CodexLogUsageScannerTestFixtures.fixedRates())
        XCTAssertNil(scan)
    }

    func testScanCachesUnchangedFilesAndPicksUpNewOnes() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": CodexLogFixture.tokenCount(
                timestamp: day, last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
            )
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let first = await scanner.scan(pricing: CodexLogUsageScannerTestFixtures.fixedRates())
        XCTAssertEqual(first?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)

        try CodexLogFixture.tokenCount(
            timestamp: day, last: CodexLogFixture.usage(input: 30, output: 20), model: "gpt-5.2"
        ).write(to: home.appendingPathComponent("sessions/rollout-b.jsonl"), atomically: true, encoding: .utf8)

        let second = await scanner.scan(pricing: CodexLogUsageScannerTestFixtures.fixedRates())
        XCTAssertEqual(second?.series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
    }

    /// Manual parity harness against the real logs on this machine: prints per-day totals to compare
    /// with `ccusage codex daily --json --offline`. Gated like the other live tests.
    func testParityAgainstRealLocalLogs() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_CODEX_PARITY"] == "1")
        let scanner = CodexLogUsageScanner()
        let result = await scanner.scan(pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        for day in scan.series.daily.sorted(by: { $0.date < $1.date }) {
            print("PARITY \(day.date) tokens=\(day.totalTokens) cost=\(day.costUSD.map { String(format: "%.4f", $0) } ?? "nil")")
        }
        if !scan.unknownModelsByDay.isEmpty {
            print("PARITY unknown models: \(scan.unknownModelsByDay)")
        }
    }

    func testScanPricesRealCodexModelsFromBundledSnapshots() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-a.jsonl": [
                CodexLogFixture.turnContext(timestamp: day, model: "gpt-5.3-codex"),
                CodexLogFixture.tokenCount(
                    timestamp: day,
                    last: CodexLogFixture.usage(input: 1_000_000, output: 0)
                )
            ].joined(separator: "\n")
        ])
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(pricing: TestPricing.bundled)
        let today = scan?.series.daily.first

        // gpt-5.3-codex must resolve in the bundled LiteLLM snapshot and price > $0.
        XCTAssertTrue(scan?.unknownModelsByDay.isEmpty ?? false)
        XCTAssertGreaterThan(today?.costUSD ?? 0, 0)
    }
}
