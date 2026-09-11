import XCTest
@testable import OpenUsage

final class ClaudeWorkflowUsageTests: XCTestCase {
    private let pricing = ModelPricing(
        supplement: PricingSupplement(), primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    func testWorkflowOwnershipAndBackfillAcrossAccounts() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        func usage(_ id: String, _ tokens: Int) -> String {
            ClaudeLogFixture.usageLine(timestamp: timestamp, input: tokens, output: 0,
                                       costUSD: 1, messageID: id, requestID: id)
        }
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/a.jsonl": #"{"ownerOrganizationUuid":"org-a","ownerAccountUuid":"user-a"}"#,
            "workspace/a/subagents/workflows/wf-1/agent-a.jsonl": usage("a", 100),
            "workspace/a/subagents/workflows/wf-2/agent-a.jsonl": usage("a", 100), // replay
            "workspace/b.jsonl": #"{"ownerOrganizationUuid":"org-b","ownerAccountUuid":"user-a"}"#,
            "workspace/b/subagents/workflows/wf-1/agent-b.jsonl": usage("b", 200),
            "workspace/foreign.jsonl": #"{"ownerOrganizationUuid":"org-a","ownerAccountUuid":"user-b"}"#,
            "workspace/foreign/subagents/workflows/wf-1/agent.jsonl": usage("foreign", 400),
            "workspace/unknown.jsonl": "{}",
            "workspace/unknown/subagents/workflows/wf-1/agent.jsonl": usage("unknown", 800),
            "workspace/orphan/subagents/workflows/wf-1/agent.jsonl": usage("orphan", 1600),
            "workspace/conflict.jsonl": #"{"ownerOrganizationUuid":"org-a"}"# + "\n" +
                #"{"ownerOrganizationUuid":"org-b"}"#,
            "workspace/conflict/subagents/workflows/wf-1/agent.jsonl": usage("conflict", 3200)
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home }, incrementalScanner: cache,
            accountUUID: "user-a", organizationUUID: "org-a"
        )
        let first = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(first?.series.daily.first?.costUSD, 1)
        let other = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home }, incrementalScanner: cache,
            accountUUID: "user-a", organizationUUID: "org-b"
        )
        let otherResult = await other.scan(now: now, pricing: pricing)
        XCTAssertEqual(otherResult?.series.daily.first?.totalTokens, 200)

        // A running workflow appends usage; shared caching must pick up the new records.
        let agent = home.appendingPathComponent(".claude/projects/workspace/a/subagents/workflows/wf-1/agent-a.jsonl")
        try (usage("a", 100) + "\n" + usage("new", 50)).write(to: agent, atomically: true, encoding: .utf8)
        let refreshed = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(refreshed?.series.daily.first?.totalTokens, 150)

        // Reassigning the parent must also invalidate ownership for its unchanged descendants.
        try #"{"ownerOrganizationUuid":"org-b","ownerAccountUuid":"user-a"}"#
            .write(to: home.appendingPathComponent(".claude/projects/workspace/a.jsonl"),
                   atomically: true, encoding: .utf8)
        let reassigned = await scanner.scan(now: now, pricing: pricing)
        XCTAssertTrue(reassigned?.series.daily.isEmpty ?? true)
    }

    func testWorkflowUsesParentDesktopIndex() async throws {
        let now = Date()
        let session = "11111111-1111-4111-8111-111111111111"
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/\(session).jsonl": "{}",
            "workspace/\(session)/subagents/workflows/wf-1/agent.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 123, output: 0,
                costUSD: 1, messageID: "agent", requestID: "agent"
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/user-a/org-a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"cliSessionId":"\#(session)"}"#
            .write(to: directory.appendingPathComponent("local_session.json"), atomically: true, encoding: .utf8)
        for (account, org, expected) in [("user-a", "org-a", 123), ("user-b", "org-a", 0), ("user-a", "org-b", 0)] {
            let scanner = ClaudeLogUsageScanner(
                environment: FakeEnvironment([:]), homeDirectory: { home },
                incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
                accountUUID: account, organizationUUID: org
            )
            let result = await scanner.scan(now: now, pricing: pricing)
            XCTAssertEqual(result?.series.daily.first?.totalTokens ?? 0, expected)
        }
    }
}
