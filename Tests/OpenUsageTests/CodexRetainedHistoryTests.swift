import XCTest
@testable import OpenUsage

@MainActor
final class CodexRetainedHistoryTests: XCTestCase {
    func testPendingHistoryDoesNotAddNoDataBadgeBeforeStoreRestoresHistory() async {
        let gate = PricingGate()
        let provider = CodexProvider.isolated(
            localHistoryWait: .zero,
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            pricing: { await gate.value() }
        )
        let snapshot = await provider.snapshot(mapped: CodexMappedUsage(plan: nil, lines: []))
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertTrue(snapshot.lines.isEmpty, "Pending history must not claim there is no usage")
        await gate.release()
    }

    func testCompletedEmptyHistoryStillShowsNoDataBadge() async {
        let provider = CodexProvider.isolated(
            localHistoryWait: .seconds(1),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            pricing: { ModelPricing(supplement: PricingSupplement(),
                                    primary: PricingCatalog(entries: [:]), secondary: PricingCatalog(entries: [:])) }
        )
        let snapshot = await provider.snapshot(mapped: CodexMappedUsage(plan: nil, lines: []))
        XCTAssertNil(snapshot.warning)
        XCTAssertTrue(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    func testLaterSnapshotCollectsHistoryAndKeepsFreshQuota() async throws {
        let gate = PricingGate()
        let now = OpenUsageISO8601.date(from: "2026-02-20T14:30:00Z")!
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-retained.jsonl": [
                CodexLogFixture.turnContext(timestamp: "2026-02-20T14:00:00Z", model: "gpt-5.2"),
                CodexLogFixture.tokenCount(timestamp: "2026-02-20T14:01:00Z",
                                           last: CodexLogFixture.usage(input: 100, output: 50))
            ].joined(separator: "\n")
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = CodexProvider.isolated(
            localHistoryWait: .zero,
            logUsageScanner: CodexLogFixture.scanner(home: home),
            now: { now },
            pricing: { await gate.value() }
        )
        func quota(_ used: Double) -> CodexMappedUsage {
            CodexMappedUsage(plan: "Pro", lines: [.progress(
                label: "Weekly", used: used, limit: 100, format: .percent
            )])
        }
        let first = await provider.snapshot(mapped: quota(58))
        XCTAssertNotNil(first.warning)
        XCTAssertNil(first.usageHistory)
        let second = await provider.snapshot(mapped: quota(19))
        XCTAssertNotNil(second.warning)
        XCTAssertEqual(second.line(label: "Weekly"), quota(19).lines.first)
        await gate.release()
        var completed = second
        for _ in 0..<100 {
            completed = await provider.snapshot(mapped: quota(7))
            if completed.usageHistory != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(completed.usageHistory)
        XCTAssertNotNil(completed.line(label: "Today"))
        XCTAssertNil(completed.warning)
        XCTAssertEqual(completed.line(label: "Weekly"), quota(7).lines.first)
        let starts = await gate.starts
        XCTAssertEqual(starts, 1)
    }
}

private actor PricingGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var starts = 0

    func value() async -> ModelPricing {
        starts += 1
        if !released { await withCheckedContinuation { continuation = $0 } }
        return ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            "gpt-5.2": ModelRates(inputPerMillion: 1, outputPerMillion: 3,
                                 cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
        ]),
                            secondary: PricingCatalog(entries: [:]))
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
