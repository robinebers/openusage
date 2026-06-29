import XCTest
@testable import OpenUsage

/// Verifies the Swift mapper against a captured live Z.ai API response. Both endpoints are
/// undocumented internal APIs, so this guards the mapping against the real shape — not just the
/// fixtures in `ZAIProviderTests`. Anonymized: the key, customer id, and agreement number are gone;
/// only the structural fields the mapper reads remain. Run locally with `swift test --filter ZAILive`.
final class ZAILiveResponseMappingTests: XCTestCase {
    // Captured from a GLM Coding Pro plan on 2026-06-29. Strips PII; keeps the fields the mapper reads.
    private let liveQuota = #"""
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17,"nextResetTime":1782724971179},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3,"nextResetTime":1783305486997},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":0,"remaining":1000,"percentage":0,"nextResetTime":1785292686976,"usageDetails":[{"modelCode":"search-prime","usage":0},{"modelCode":"web-reader","usage":0},{"modelCode":"zread","usage":0}]}
    ],"level":"pro"},"success":true}
    """#

    private let liveSubscription = #"""
    {"code":200,"msg":"Operation successful","data":[{"productName":"GLM Coding Pro","status":"VALID","nextRenewTime":"2026-07-29","billingCycle":"monthly","inCurrentPeriod":true}],"success":true}
    """#

    func testMapsLiveResponseToSessionWeeklyAndWebSearches() throws {
        let mapped = ZAIUsageMapper.map(
            quotaBody: Data(liveQuota.utf8),
            subscriptionBody: Data(liveSubscription.utf8)
        )

        XCTAssertEqual(mapped.plan, "GLM Coding Pro")

        let session = try XCTUnwrap(progress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 17, accuracy: 0.001)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 3, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        let web = try XCTUnwrap(progress(mapped.lines, "Web Searches"))
        XCTAssertEqual(web.used, 0, accuracy: 0.001)
        XCTAssertEqual(web.limit, 1000, accuracy: 0.001)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, _, let period, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, period)
    }
}
