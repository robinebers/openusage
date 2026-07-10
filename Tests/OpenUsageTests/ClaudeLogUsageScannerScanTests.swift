import XCTest
@testable import OpenUsage

/// End-to-end file discovery, cache invalidation, and session-root coverage for the Claude log scanner.
extension ClaudeLogUsageScannerTests {
    // MARK: - End-to-end scan

    func testScanReadsFixtureHomeAndRescanPicksUpNewLines() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session-1.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                messageID: "msg-1", requestID: "req-1"
            )
        ])
        let scanner = ClaudeLogFixture.scanner(home: home)

        let firstScan = await scanner.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstScan)
        XCTAssertEqual(first.series.daily.count, 1)
        XCTAssertEqual(first.series.daily[0].totalTokens, 150)
        XCTAssertEqual(first.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)

        // Append a second session file; the rescan must pick it up (per-file cache invalidation).
        let newFile = home.appendingPathComponent("projects/project-a/session-2.jsonl")
        try ClaudeLogFixture.usageLine(
            timestamp: timestamp, input: 10, output: 5, costUSD: 0.05,
            messageID: "msg-2", requestID: "req-2"
        ).write(to: newFile, atomically: true, encoding: .utf8)

        let secondScan = await scanner.scan(now: now, pricing: pricing)
        let second = try XCTUnwrap(secondScan)
        XCTAssertEqual(second.series.daily[0].totalTokens, 165)
        XCTAssertEqual(second.series.daily[0].costUSD ?? 0, 0.30, accuracy: 1e-9)
    }

    func testScanDeduplicatesReplaysAcrossFiles() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        // The same message replayed in a sidechain session file under a new request id: only the
        // parent's tokens may count.
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/parent.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                messageID: "msg-shared", requestID: "req-parent", isSidechain: false
            ),
            "project-a/sidechain.jsonl": ClaudeLogFixture.usageLine(
                timestamp: timestamp, input: 90_000, output: 10, costUSD: 9.99,
                messageID: "msg-shared", requestID: "req-replay", isSidechain: true
            )
        ])
        let scanner = ClaudeLogFixture.scanner(home: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 150)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)
    }

    func testScanSkipsFilesLastTouchedBeforeTheWindow() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/old.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now.addingTimeInterval(-90 * 86_400)),
                input: 100, output: 50, costUSD: 0.25
            )
        ])
        let oldFile = home.appendingPathComponent("projects/project-a/old.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: oldFile.path
        )
        let scanner = ClaudeLogFixture.scanner(home: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    func testScanReturnsNilWithoutClaudeHome() async {
        let scanner = ClaudeLogFixture.scanner(home: nil)
        let scan = await scanner.scan(now: Date(), pricing: pricing)
        XCTAssertNil(scan)
    }

    /// Manual parity harness against the real logs on this machine: prints per-day totals to compare
    /// with `ccusage daily --json --offline`. Gated like the other live tests.
    func testParityAgainstRealLocalLogs() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_CLAUDE_PARITY"] == "1")
        let scanner = ClaudeLogUsageScanner()
        let result = await scanner.scan(now: Date(), pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        for day in scan.series.daily.sorted(by: { $0.date < $1.date }) {
            print("PARITY \(day.date) tokens=\(day.totalTokens) cost=\(day.costUSD.map { String(format: "%.4f", $0) } ?? "nil")")
        }
        if !scan.unknownModelsByDay.isEmpty {
            print("PARITY unknown models: \(scan.unknownModelsByDay)")
        }
    }

    // MARK: - Cowork session roots

    func testScanSumsTerminalAndCoworkLogs() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeUserHome(
            claudeFiles: [
                "project-a/terminal.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                    messageID: "msg-terminal", requestID: "req-terminal"
                )
            ],
            coworkSessions: [
                "group-1/sub-1/local_a": [
                    "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 10, output: 5, costUSD: 0.05,
                        messageID: "msg-cowork", requestID: "req-cowork"
                    )
                ],
                "group-1/sub-1/agent/local_ditto_a": [
                    "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 2, output: 3, costUSD: 0.01,
                        messageID: "msg-ditto", requestID: "req-ditto"
                    )
                ]
            ]
        )
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 170)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.31, accuracy: 1e-9)
    }

    func testScanFindsCoworkLogsWithoutTerminalClaudeHome() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(coworkSessions: [
            "group-1/sub-1/local_a": [
                "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: OpenUsageISO8601.string(from: now), input: 10, output: 5, costUSD: 0.05
                )
            ]
        ])
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 15)
    }

    func testScanDeduplicatesReplaysAcrossTerminalAndCoworkLogs() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeUserHome(
            claudeFiles: [
                "project-a/parent.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                    messageID: "msg-shared", requestID: "req-parent", isSidechain: false
                )
            ],
            coworkSessions: [
                "group-1/sub-1/local_a": [
                    "workspace/replay.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 90_000, output: 10, costUSD: 9.99,
                        messageID: "msg-shared", requestID: "req-replay", isSidechain: true
                    )
                ]
            ]
        )
        let scanner = ClaudeLogFixture.scanner(userHome: home)

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 150)
        XCTAssertEqual(scan.series.daily[0].costUSD ?? 0, 0.25, accuracy: 1e-9)
    }

    func testScanAcceptsProjectsDirItselfInConfigDir() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 10, output: 5, costUSD: 0.01
            )
        ])
        // ccusage accepts `CLAUDE_CONFIG_DIR` pointing at the `projects/` dir itself.
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.appendingPathComponent("projects").path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.count, 1)
        XCTAssertEqual(scan.series.daily[0].totalTokens, 15)
    }
}
