import Foundation
import Testing
@testable import OpenUsage

struct OpenUsageISO8601Tests {
    @Test func normalizesMicrosecondsWithoutTimezoneLikeClaudeAPI() {
        let date = OpenUsageISO8601.date(from: "2099-01-01T00:00:00.123456")
        #expect(date != nil)
        #expect(OpenUsageISO8601.string(from: date!) == "2099-01-01T00:00:00.123Z")
    }

    @Test func normalizesSpaceSeparatedUTC() {
        let date = OpenUsageISO8601.date(from: "2099-01-01 00:00:00 UTC")
        #expect(date != nil)
    }
}
