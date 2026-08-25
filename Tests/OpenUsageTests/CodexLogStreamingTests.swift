import Foundation
import XCTest
@testable import OpenUsage

final class CodexLogStreamingTests: XCTestCase {
    func testStreamingPreservesReplayBaselineModelAndServiceTierAcrossBatches() async throws {
        let created = "2026-05-12T08:03:00.000Z"
        let createdEpoch = Int(try XCTUnwrap(OpenUsageISO8601.date(from: created)).timeIntervalSince1970)
        let padding = String(repeating: "x", count: JSONLStreamingReader.readChunkBytes + 17)
        let ignoredRecord = #"{"type":"response_item","payload":"\#(padding)"}"#
        let text = [
            CodexLogFixture.subagentSessionMeta(timestamp: created),
            ignoredRecord,
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:00.100Z", startedAt: createdEpoch - 60),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:03:00.200Z",
                totals: CodexLogFixture.usage(input: 1_000, output: 200)
            ),
            ignoredRecord,
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:03:00.300Z", model: "gpt-5.2"),
            CodexLogFixture.threadSettingsApplied(
                timestamp: "2026-05-12T08:03:00.400Z",
                serviceTier: "priority"
            ),
            ignoredRecord,
            CodexLogFixture.taskStarted(timestamp: "2026-05-12T08:03:01.000Z", startedAt: createdEpoch + 1),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:04:00.000Z",
                totals: CodexLogFixture.usage(input: 1_100, output: 220)
            ),
            ignoredRecord,
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:05:00.000Z",
                totals: CodexLogFixture.usage(input: 1_200, output: 240)
            )
        ].joined(separator: "\n")
        let home = try CodexLogFixture.makeHome(files: ["sessions/rollout.jsonl": text])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)

        let result = await scanner.scan(
            daysBack: 1,
            now: try XCTUnwrap(OpenUsageISO8601.date(from: "2026-05-12T09:00:00.000Z")),
            pricing: TestPricing.bundled
        )

        let expectedEvents = CodexLogUsageScanner.parseFile(Data(text.utf8))
        XCTAssertEqual(expectedEvents.map(\.isFast), [true, true])
        XCTAssertEqual(expectedEvents.map(\.model), ["gpt-5.2", "gpt-5.2"])
        let expected = CodexLogUsageScanner.aggregate(
            events: expectedEvents,
            since: .distantPast,
            pricing: TestPricing.bundled
        )
        let day = try XCTUnwrap(result?.series.daily.first)
        XCTAssertEqual(day.totalTokens, 240)
        XCTAssertEqual(
            try XCTUnwrap(day.costUSD),
            try XCTUnwrap(expected.series.daily.first?.costUSD),
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(result?.modelUsage?.daily.first?.models.map(\.model), ["gpt-5.2"])
    }

    func testStreamingDoesNotCarryRolloutStateIntoTheNextFile() async throws {
        let first = [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5)
            )
        ].joined(separator: "\n")
        let second = CodexLogFixture.tokenCount(
            timestamp: "2026-05-12T08:02:00.000Z",
            last: CodexLogFixture.usage(input: 20, output: 10)
        )
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/a.jsonl": first,
            "sessions/b.jsonl": second
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let scanner = IncrementalJSONLScanner<CodexLogUsageScanner.Event>()

        let events = await scanner.items(
            from: files,
            since: .distantPast,
            initialState: CodexLogFileParser(),
            parse: { data, state in state.parse(data) }
        )

        XCTAssertEqual(events?.map(\.model), ["gpt-5.2", "gpt-5"])
    }
}
