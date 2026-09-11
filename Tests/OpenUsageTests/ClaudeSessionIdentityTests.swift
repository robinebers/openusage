import Foundation
import Synchronization
import XCTest
@testable import OpenUsage

final class ClaudeSessionIdentityTests: XCTestCase {
    private var pricing: ModelPricing {
        ModelPricing(supplement: PricingSupplement(),
                     primary: PricingCatalog(entries: [:]), secondary: PricingCatalog(entries: [:]))
    }

    func testLateOwnerAcrossChunkBoundaryAndFinalUnterminatedRecord() {
        let padding = String(repeating: " ", count: 1_048_560)
        let owner = #"{"ownerOrganizationUuid":"ORG-A","ownerAccountUuid":"USER-A"}"#
        let data = Data((padding + owner).utf8)
        XCTAssertEqual(ClaudeSessionIdentity.parse(data), .owned(organizationID: "org-a", accountID: "user-a"))
        XCTAssertEqual(ClaudeSessionIdentity.parse(Data((String(repeating: "{}\n", count: 600) + owner).utf8)),
                       .owned(organizationID: "org-a", accountID: "user-a"))
    }

    func testConflictsAndUnattributedAreDistinct() {
        let first = #"{"ownerOrganizationUuid":"org-a","ownerAccountUuid":"user-a"}"#
        for second in [
            #"{"ownerOrganizationUuid":"org-b","ownerAccountUuid":"user-a"}"#,
            #"{"ownerOrganizationUuid":"org-a","ownerAccountUuid":"user-b"}"#
        ] {
            XCTAssertEqual(ClaudeSessionIdentity.parse(Data((first + "\n" + second).utf8)), .conflicted)
        }
        XCTAssertEqual(ClaudeSessionIdentity.parse(Data("{}\n".utf8)), .unattributed)
    }

    func testCancellationInsideHugeRecord() {
        var checks = 0
        let result = ClaudeSessionIdentity.parse(Data(repeating: 32, count: 5 * 1_048_576)) {
            checks += 1
            return checks == 3
        }
        XCTAssertNil(result)
        XCTAssertEqual(checks, 3)
    }

    func testParentReadOnceAndConflictsCachedUntilFileChanges() async throws {
        let first = #"{"ownerOrganizationUuid":"org-a"}"#
        let conflict = first + "\n" + #"{"ownerOrganizationUuid":"org-b"}"#
        var files = ["workspace/session.jsonl": conflict]
        for index in 0..<200 {
            files["workspace/session/subagents/agent-\(index).jsonl"] = "{}"
        }
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: files)
        defer { try? FileManager.default.removeItem(at: home) }
        let reads = Mutex(0)
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            organizationUUID: "org-a", allowsUnattributedSessions: true,
            readOwnershipData: { url in
                reads.withLock { $0 += 1 }
                return try Data(contentsOf: url)
            }
        )
        for _ in 0..<2 {
            let result = await scanner.scan(pricing: pricing)
            XCTAssertNil(result, "Conflicts must be excluded even when unattributed sessions are allowed")
        }
        XCTAssertEqual(reads.withLock { $0 }, 1)
        try first.write(to: home.appendingPathComponent(".claude/projects/workspace/session.jsonl"),
                        atomically: true, encoding: .utf8)
        let recovered = await scanner.scan(pricing: pricing)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    func testRecentSubagentKeepsOwnershipFromOldParent() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": #"{"ownerOrganizationUuid":"org-a"}"#,
            "workspace/session/subagents/a.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 10, output: 5, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60 * 86_400)],
            ofItemAtPath: home.appendingPathComponent(".claude/projects/workspace/session.jsonl").path
        )
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            organizationUUID: "org-a"
        )
        let result = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(result?.series.daily.first?.totalTokens, 15)
    }

    func testReadFailureIsRetriedOnlyOnNextPass() async throws {
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": "{}",
            "workspace/session/subagents/a.jsonl": "{}",
            "workspace/session/subagents/b.jsonl": "{}"
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let reads = Mutex(0)
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            organizationUUID: "org-a", allowsUnattributedSessions: true,
            readOwnershipData: { _ in
                let count = reads.withLock { $0 += 1; return $0 }
                if count == 1 { throw CocoaError(.fileReadUnknown) }
                return Data("{}".utf8)
            }
        )
        let failed = await scanner.scan(pricing: pricing)
        XCTAssertNil(failed)
        XCTAssertEqual(reads.withLock { $0 }, 1)
        let recovered = await scanner.scan(pricing: pricing)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }
}
