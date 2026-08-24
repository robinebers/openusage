import Foundation
import XCTest
@testable import OpenUsage

final class GrokLogUsageScannerTests: XCTestCase {
    private let since = OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z")!

    func testUsesRecordedPerModelCostAndDoesNotCountReasoningTwice() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-4.6-build",
            input: 1_000_000,
            cached: 700_000,
            output: 50_000,
            reasoning: 20_000,
            costUsdTicks: 2_357_158_800,
            eventID: "turn-1"
        )

        let usage = scan(line)
        let day = try XCTUnwrap(usage.series.daily.first)

        XCTAssertEqual(day.totalTokens, 1_050_000)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.23571588, accuracy: 0.00000001)
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-4.6-build"])
    }

    func testFallsBackToSharedPricingAndSeparatesCacheBuckets() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-4.5-build",
            input: 1_000_000,
            cached: 700_000,
            cacheWrite: 100_000,
            output: 250_000
        )

        let day = try XCTUnwrap(scan(line).series.daily.first)

        // 200k input + 100k cache write at $2/M, 700k cache read at $0.5/M, 250k output at $6/M.
        XCTAssertEqual(day.totalTokens, 1_250_000)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 2.45, accuracy: 0.0001)
    }

    func testSplitsCompletedTurnAcrossModelsWithoutDuplicatingTheEvent() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-4.5-build",
            input: 100,
            output: 20,
            costUsdTicks: 1_000_000_000,
            eventID: "shared-turn",
            additionalModels: [
                "grok-4.6-build": [
                    "inputTokens": 200,
                    "outputTokens": 30,
                    "costUsdTicks": 2_000_000_000
                ]
            ]
        )

        let usage = scan(line)
        let day = try XCTUnwrap(usage.series.daily.first)

        XCTAssertEqual(day.totalTokens, 350)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.3, accuracy: 0.0001)
        XCTAssertEqual(
            Set(usage.modelUsage?.daily.first?.models.map(\.model) ?? []),
            ["grok-4.5-build", "grok-4.6-build"]
        )
    }

    func testSingleModelFallsBackToTurnLevelRecordedCost() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-4.6-build",
            input: 1_000_000,
            costUsdTicks: 1_250_000_000,
            includePerModelCost: false
        )

        let day = try XCTUnwrap(scan(line).series.daily.first)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.125, accuracy: 0.0001)
    }

    func testRecordedCostAllowsUnknownModelWithoutPricingWarning() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-future-model",
            input: 500_000,
            costUsdTicks: 3_000_000_000
        )

        let usage = scan(line)

        let day = try XCTUnwrap(usage.series.daily.first)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.3, accuracy: 0.0001)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
    }

    func testUnknownModelWithoutRecordedCostIsExcludedAndWarns() {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-future-model",
            input: 500_000
        )

        let usage = scan(line)

        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-future-model"])
    }

    func testZeroRecordedCostStillCountsMeasuredTokens() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-future-model",
            input: 500,
            costUsdTicks: 0
        )

        let day = try XCTUnwrap(scan(line).series.daily.first)

        XCTAssertEqual(day.totalTokens, 500)
        XCTAssertEqual(day.costUSD, 0)
    }

    func testPrefersMillisecondAgentTimestampOverCoarseOuterTimestamp() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-09T10:00:00.000Z",
            model: "grok-build",
            input: 1_000,
            agentTimestampMs: 1_781_089_200_456
        )

        let entry = try XCTUnwrap(GrokLogUsageScanner.parseFile(Data(line.utf8)).first)

        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, 1_781_089_200.456, accuracy: 0.0001)
    }

    func testParsesUnixSecondTimestamps() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-build",
            input: 1_000,
            numericTimestamp: true
        )

        XCTAssertEqual(try XCTUnwrap(scan(line).series.daily.first).date, "2026-06-10")
    }

    func testParsesTopLevelUpdateEnvelope() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-build",
            input: 1_000,
            nested: false
        )

        XCTAssertEqual(try XCTUnwrap(scan(line).series.daily.first).totalTokens, 1_000)
    }

    func testSkipsIncompleteMalformedAndOutOfWindowTurns() throws {
        let incomplete = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-build",
            input: 1_000,
            sessionUpdate: "turn_started"
        )
        let stale = GrokLogFixture.completedTurn(
            timestamp: "2026-05-30T10:00:00.000Z",
            model: "grok-build",
            input: 2_000
        )
        let completed = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-build",
            input: 3_000
        )

        let usage = scan([incomplete, "{broken turn_completed", stale, completed].joined(separator: "\n"))

        XCTAssertEqual(try XCTUnwrap(usage.series.daily.first).totalTokens, 3_000)
    }

    func testCopiedEventIDsAreCountedOnce() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-build",
            input: 1_000,
            eventID: "duplicate-event"
        )

        let usage = scan([line, line].joined(separator: "\n"))

        XCTAssertEqual(try XCTUnwrap(usage.series.daily.first).totalTokens, 1_000)
    }

    func testRecursivelyScansSessionLedgersAndIgnoresOtherJSONLFiles() async throws {
        let first = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z", model: "grok-build", input: 100, eventID: "copied-turn"
        )
        let second = GrokLogFixture.completedTurn(
            timestamp: "2026-06-11T10:00:00.000Z", model: "grok-build", input: 200
        )
        let ignored = GrokLogFixture.completedTurn(
            timestamp: "2026-06-12T10:00:00.000Z", model: "grok-build", input: 300
        )
        let home = try GrokLogFixture.makeHome(files: [
            "project-a/session-a/updates.jsonl": first,
            "project-b/session-b/updates.jsonl": second,
            "project-b/session-b/debug.jsonl": ignored,
            "project-c/copied-session/updates.jsonl": first
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = GrokLogFixture.scanner(home: home)

        let usage = await scanner.scan(
            daysBack: 30,
            now: OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!,
            pricing: TestPricing.bundled
        )

        XCTAssertEqual(usage?.series.daily.map(\.date), ["2026-06-11", "2026-06-10"])
        XCTAssertEqual(usage?.series.daily.map(\.totalTokens), [200, 100])
    }

    func testSkipsSubagentSessionsAlreadyIncludedInCoordinatorTotals() async throws {
        let coordinator = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z",
            model: "grok-4.6-build",
            input: 300,
            costUsdTicks: 30_000_000_000,
            eventID: "coordinator-turn"
        )
        let subagent = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:01:00.000Z",
            model: "grok-4.6-build",
            input: 100,
            costUsdTicks: 10_000_000_000,
            eventID: "subagent-turn"
        )
        let fork = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:02:00.000Z",
            model: "grok-4.6-build",
            input: 200,
            costUsdTicks: 20_000_000_000,
            eventID: "fork-turn"
        )
        let legacy = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T11:00:00.000Z",
            model: "grok-4.6-build",
            input: 50,
            costUsdTicks: 5_000_000_000,
            eventID: "legacy-turn"
        )
        let home = try GrokLogFixture.makeHome(files: [
            "project/coordinator/updates.jsonl": coordinator,
            "project/coordinator/summary.json": #"{"session_kind":"coordinator"}"#,
            "project/coordinator/subagents/worker/updates.jsonl": subagent,
            "project/coordinator/subagents/worker/summary.json": #"{"session_kind":"subagent"}"#,
            "project/fork/updates.jsonl": fork,
            "project/fork/summary.json": #"{"session_kind":"subagent_fork"}"#,
            "project/legacy/updates.jsonl": legacy
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let usage = await GrokLogFixture.scanner(home: home).scan(
            daysBack: 30,
            now: OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!,
            pricing: TestPricing.bundled
        )
        let day = try XCTUnwrap(usage?.series.daily.first)

        XCTAssertEqual(day.totalTokens, 350, "subagent and fork tokens are already included in their coordinator")
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 3.5, accuracy: 0.0001)
    }

    func testSkipsSessionWithMalformedSummaryInsteadOfGuessingItsKind() async throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z", model: "grok-build", input: 1_000
        )
        let home = try GrokLogFixture.makeHome(files: [
            "project/session/updates.jsonl": line,
            "project/session/summary.json": "{invalid"
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let usage = await GrokLogFixture.scanner(home: home).scan(pricing: TestPricing.bundled)

        XCTAssertNil(usage)
    }

    func testReadsWhitespaceTrimmedGrokHomeOverride() async throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-06-10T10:00:00.000Z", model: "grok-build", input: 1_000
        )
        let home = try GrokLogFixture.makeHome(files: ["project/session/updates.jsonl": line])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = GrokLogUsageScanner(
            environment: FakeEnvironment(["GROK_HOME": "  \(home.path)  "]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
            incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.Entry>()
        )

        let usage = await scanner.scan(
            daysBack: 30,
            now: OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!,
            pricing: TestPricing.bundled
        )

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 1_000)
    }

    func testReturnsNilWhenSessionLedgersAreMissing() async {
        let scanner = GrokLogFixture.scanner(home: nil)

        let usage = await scanner.scan(pricing: TestPricing.bundled)

        XCTAssertNil(usage)
    }

    func testDoesNotFallBackToTheDebugLogWhenSessionsAreMissing() async throws {
        let home = try GrokLogFixture.makeHome(files: [:])
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "debug log content".write(
            to: logs.appendingPathComponent("unified.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let usage = await GrokLogFixture.scanner(home: home).scan(pricing: TestPricing.bundled)

        XCTAssertNil(usage)
    }

    private func scan(_ text: String) -> LogUsageScan {
        let entries = GrokLogUsageScanner.parseFile(Data(text.utf8))
        return GrokLogUsageScanner.aggregate(
            entries: GrokLogUsageScanner.dedup(entries),
            since: since,
            pricing: TestPricing.bundled
        )
    }
}

enum GrokLogFixture {
    static func makeHome(files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-grok-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let file = sessions.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return home
    }

    static func scanner(home: URL?) -> GrokLogUsageScanner {
        GrokLogUsageScanner(
            environment: FakeEnvironment(home.map { ["GROK_HOME": $0.path] } ?? [:]),
            homeDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-grok-home")
            },
            incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.Entry>()
        )
    }

    static func completedTurn(
        timestamp: String,
        model: String,
        input: Int,
        cached: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        costUsdTicks: Int? = nil,
        eventID: String? = nil,
        agentTimestampMs: Int? = nil,
        numericTimestamp: Bool = false,
        nested: Bool = true,
        includePerModelCost: Bool = true,
        additionalModels: [String: [String: Int]] = [:],
        sessionUpdate: String = "turn_completed"
    ) -> String {
        var modelValues: [String: Int] = [
            "inputTokens": input,
            "cachedReadTokens": cached,
            "cacheCreationTokens": cacheWrite,
            "outputTokens": output,
            "reasoningTokens": reasoning
        ]
        if let costUsdTicks, includePerModelCost {
            modelValues["costUsdTicks"] = costUsdTicks
        }
        var models = additionalModels
        models[model] = modelValues

        var usage: [String: Any] = ["inputTokens": input, "outputTokens": output, "modelUsage": models]
        if let costUsdTicks { usage["costUsdTicks"] = costUsdTicks }
        let update: [String: Any] = ["sessionUpdate": sessionUpdate, "usage": usage]
        var metadata: [String: Any] = [:]
        if let eventID { metadata["eventId"] = eventID }
        if let agentTimestampMs { metadata["agentTimestampMs"] = agentTimestampMs }

        let parsedTimestamp = OpenUsageISO8601.date(from: timestamp)!
        var object: [String: Any] = [
            "timestamp": numericTimestamp ? Int(parsedTimestamp.timeIntervalSince1970) : timestamp
        ]
        if nested {
            var params: [String: Any] = ["sessionId": "session-1", "update": update]
            if !metadata.isEmpty { params["_meta"] = metadata }
            object["params"] = params
            object["method"] = "session/update"
        } else {
            object["update"] = update
            if !metadata.isEmpty { object["_meta"] = metadata }
        }

        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
