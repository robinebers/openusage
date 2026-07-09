import XCTest
@testable import OpenUsage

final class CopilotUsageMapperTests: XCTestCase {
    func testMapsPaidCreditsAndChatAsPercentUsed() throws {
        let mapped = try CopilotUsageMapper.map(body: CopilotTestFixtures.paidBody())

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Credits")?.used, 59)
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Chat")?.used, 5)
        XCTAssertNotNil(CopilotTestFixtures.progress(mapped.lines, "Credits")?.resetsAt)
        XCTAssertEqual(
            CopilotTestFixtures.progress(mapped.lines, "Credits")?.periodDurationMs,
            CopilotUsageMapper.periodMs
        )
    }

    func testSuppressesUnlimitedAndSentinelBuckets() throws {
        // Paid plans report chat/completions as unlimited — both the explicit flag and the -1
        // entitlement/remaining sentinel — which carry no real meter and must be suppressed, leaving
        // just Credits.
        var body = CopilotTestFixtures.paidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["unlimited": true, "entitlement": 0, "remaining": 0, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(CopilotTestFixtures.progress(mapped.lines, "Chat"))
        XCTAssertNil(CopilotTestFixtures.progress(mapped.lines, "Completions"))
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Credits")?.used, 59)
    }

    func testEmitsExtraUsageWhenOveragePermitted() throws {
        var body = CopilotTestFixtures.paidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 36
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(CopilotTestFixtures.countValue(mapped.lines, "Extra Usage"), 36)
    }

    func testShowsExtraUsageZeroWhenPermittedButUnused() throws {
        var body = CopilotTestFixtures.paidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 0
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(CopilotTestFixtures.countValue(mapped.lines, "Extra Usage"), 0)
    }

    func testSuppressesExtraUsageWhenNotPermitted() throws {
        // paidBody's premium has no overage flag → extra usage is genuinely N/A.
        let mapped = try CopilotUsageMapper.map(body: CopilotTestFixtures.paidBody())
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
    }

    func testIgnoresLegacyLimitedQuotasWhenSnapshotsPresent() throws {
        // A paid response with Credits present and chat/completions unlimited (-1) must NOT fall back to
        // the legacy limited_user_quotas path, even if the payload still carries it — doing so would show
        // free-tier Chat/Completions meters on a paid account alongside Credits.
        var body = CopilotTestFixtures.paidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["entitlement": -1, "remaining": -1, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota
        body["limited_user_quotas"] = ["chat": 100, "completions": 1000]
        body["monthly_quotas"] = ["chat": 500, "completions": 4000]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNotNil(CopilotTestFixtures.progress(mapped.lines, "Credits"))
        XCTAssertNil(CopilotTestFixtures.progress(mapped.lines, "Chat"))
        XCTAssertNil(CopilotTestFixtures.progress(mapped.lines, "Completions"))
    }

    func testSuppressesZeroEntitlementPlaceholder() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 100, "quota_id": "premium"],
                "chat": ["entitlement": 1000, "remaining": 800, "percent_remaining": 80, "quota_id": "chat"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(CopilotTestFixtures.progress(mapped.lines, "Credits"))
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Chat")?.used, 20)
    }

    func testMapsLiveFreeAccountSnapshots() throws {
        // The exact shape a free individual account returns today: real chat/completions counts in
        // quota_snapshots, a zero-entitlement premium bucket, and token_based_billing on every bucket.
        // Credits + Extra Usage suppress (no allotment / overage off); Chat + Completions render.
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_reset_date": "2099-07-01",
            "quota_snapshots": [
                "chat": ["entitlement": 200, "remaining": 182, "percent_remaining": 91.0, "overage_permitted": false, "token_based_billing": true],
                "completions": ["entitlement": 2000, "remaining": 1989, "percent_remaining": 99.4, "overage_permitted": false, "token_based_billing": true],
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 0.0, "overage_permitted": false, "token_based_billing": true]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertNil(CopilotTestFixtures.progress(mapped.lines, "Credits"))
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Chat")?.used ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(
            CopilotTestFixtures.progress(mapped.lines, "Completions")?.used ?? -1,
            0.6,
            accuracy: 0.0001
        )
    }

    func testMapsFreeTierLimitedQuotas() throws {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "limited_user_quotas": ["chat": 250, "completions": 2000],
            "monthly_quotas": ["chat": 500, "completions": 4000],
            "limited_user_reset_date": "2099-02-15"
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Chat")?.used, 50)
        XCTAssertEqual(CopilotTestFixtures.progress(mapped.lines, "Completions")?.used, 50)
        XCTAssertNotNil(CopilotTestFixtures.progress(mapped.lines, "Chat")?.resetsAt)
    }

    func testTokenBasedBillingReturnsPlanWithoutMeters() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "quota_id": "premium"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Business")
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)
    }

    func testPlaceholderOveragePermittedDoesNotEmitExtraUsageOrBlockOrgFlag() throws {
        // Regression for issue #839's second report: the org-managed placeholder carries
        // overage_permitted: true on a zero-entitlement premium bucket. That must not render a
        // meaningless "Extra Usage: 0" row — and must still flag the seat as org-managed so the
        // provider runs the org-billing lookup.
        var body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": [
                    "entitlement": 0, "remaining": 0, "unlimited": true,
                    "overage_permitted": true, "overage_count": 0, "token_based_billing": true
                ]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)

        // A paid account with a real credit pool keeps its Extra Usage row.
        body = CopilotTestFixtures.paidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 12
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let paid = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(CopilotTestFixtures.countValue(paid.lines, "Extra Usage"), 12)
        XCTAssertFalse(paid.isOrgManagedSeat)
    }

    func testThrowsQuotaUnavailableWhenEmpty() {
        XCTAssertThrowsError(try CopilotUsageMapper.map(body: ["copilot_plan": "pro"])) { error in
            XCTAssertEqual(error as? CopilotUsageError, .quotaUnavailable)
        }
    }
}
