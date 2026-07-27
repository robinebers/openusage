import Testing
import Foundation
@testable import OpenUsage

struct AntigravityLogUsageScannerTests {
    @Test
    func testParseAntigravityLogLine() {
        let sampleLog = """
        {"created_at":"2026-07-27T10:00:00Z","model":"gemini-3.6-flash","tokens":{"input":1000,"cached":200,"output":500,"thoughts":100}}
        """

        var accumulator = DailyUsageAccumulator()
        let pricing = ModelPricing.bundledForTesting()
        let since = Date(timeIntervalSince1970: 0)

        AntigravityLogUsageScanner.parse(sampleLog, since: since, pricing: pricing, into: &accumulator)

        let result = accumulator.build()
        #expect(!result.series.isEmpty)
        let total = result.series.reduce(0) { $0 + $1.tokens }
        #expect(total == 1800) // 1000 + 200 + 500 + 100
    }
}
