import XCTest
@testable import OpenUsage

final class OpenCodeGoUsageMapperTests: XCTestCase {
    func testMapsSeparateKimiAndGLMLines() {
        let body = Data("""
        {
          "quotas": [
            { "name": "Kimi for Coding", "used_percent": 12.5 },
            { "name": "GLM", "used": 80, "limit": 400 }
          ]
        }
        """.utf8)

        let lines = OpenCodeGoUsageMapper.map(body)
        XCTAssertEqual(progress(lines, "Kimi for Coding")?.used, 12.5)
        XCTAssertEqual(progress(lines, "GLM")?.used, 20)
    }

    func testZeroValuesRemainMappedAsUsageData() {
        let body = Data("""
        {
          "data": {
            "limits": [
              { "name": "kimi-coding", "used": 0, "limit": 1 },
              { "name": "GLM", "used": 0, "limit": 10 }
            ]
          }
        }
        """.utf8)

        let lines = OpenCodeGoUsageMapper.map(body)
        XCTAssertNotNil(progress(lines, "Kimi for Coding"))
        XCTAssertNotNil(progress(lines, "GLM"))
        XCTAssertNil(lines.first(where: { if case .badge(let label, let text, _, _) = $0 { return label == "Status" && text == "No usage data" } else { return false } }))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, .percent, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }
}
