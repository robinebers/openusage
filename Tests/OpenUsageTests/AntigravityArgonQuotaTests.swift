import XCTest
@testable import OpenUsage

final class AntigravityArgonQuotaTests: XCTestCase {
    private func summary(groupName: String = "Gemini 4 Argon", buckets: String) -> Data {
        Data("""
        {"groups":[
          {"displayName":"\(groupName)","buckets":[\(buckets)]},
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.8},
            {"bucketId":"gemini-weekly","remainingFraction":0.7}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-5h","remainingFraction":0.6},
            {"bucketId":"3p-weekly","remainingFraction":0.5}
          ]}
        ]}
        """.utf8)
    }

    private func assertSharedPoolsOnly(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let lines = AntigravityUsageMapper.parseQuotaSummaries([data])
        XCTAssertEqual(lines?.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"], file: file, line: line)
        XCTAssertEqual(lines?.map { metric -> Double? in
            guard case .progress(_, let used, _, _, _, _) = metric else { return nil }
            return used
        }, [20, 30, 40, 50], file: file, line: line)
    }

    func testAbsentArgonPreservesExistingFourBuckets() {
        assertSharedPoolsOnly(summary(groupName: "Unrelated group", buckets: ""))
    }

    func testUnavailableArgonPreservesSharedQuotas() {
        let unavailable = [
            "",
            #"{"bucketId":"test-id","window":"weekly"}"#,
            #"{"bucketId":"test-id","window":"weekly","remainingFraction":"unknown"}"#,
            #"{"bucketId":"test-id","window":"weekly","remainingFraction":1,"disabled":true}"#,
            #"{"bucketId":"test-id","window":"weekly","remainingAmount":100}"#
        ]
        for buckets in unavailable {
            assertSharedPoolsOnly(summary(buckets: buckets))
        }
    }

    func testOnlyExplicitArgonWeeklyGroupCanPopulateTheRow() {
        for group in ["Gemini Models", "Gemini 4 Argon Images", "Future Models"] {
            assertSharedPoolsOnly(summary(
                groupName: group,
                buckets: #"{"bucketId":"test-id","displayName":"Gemini 4 Argon Weekly Limit","window":"weekly","remainingFraction":0.1}"#
            ))
        }
        for buckets in [
            #"{"bucketId":"test-id","displayName":"Gemini 4 Argon Weekly Limit","remainingFraction":0.1}"#,
            #"{"bucketId":"test-id","window":"5h","remainingFraction":0.1}"#,
            #"{"window":"weekly","remainingFraction":0.1}"#,
            #"{"bucketId":"","window":"weekly","remainingFraction":0.1}"#,
            #"{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.1}"#
        ] {
            assertSharedPoolsOnly(summary(buckets: buckets))
        }
    }

    func testDisabledFlagRejectsMalformedValuesButAllowsOmissionNullAndFalse() {
        for value in ["true", #""true""#, #""false""#, "1", "0"] {
            assertSharedPoolsOnly(summary(buckets: """
            {"bucketId":"test-id","window":"weekly","remainingFraction":0.5,"disabled":\(value)}
            """))
        }

        for field in ["", #", "disabled":null"#, #", "disabled":false"#] {
            let lines = AntigravityUsageMapper.parseQuotaSummaries([summary(buckets: """
            {"bucketId":"test-id","window":"weekly","remainingFraction":0.5\(field)}
            """)])
            XCTAssertEqual(lines?.first { $0.label == "Argon Weekly" }, .progress(
                label: "Argon Weekly", used: 50, limit: 100, format: .percent,
                resetsAt: nil, periodDurationMs: MetricPeriod.weekMs
            ), "disabled field: \(field)")
        }
    }

    func testAmbiguousWeeklyBucketsDoNotChooseOrMergeAQuota() {
        assertSharedPoolsOnly(summary(buckets: """
        {"bucketId":"test-first","window":"weekly","remainingFraction":0.9},
        {"bucketId":"test-second","window":"weekly","remainingFraction":0.1}
        """))
    }

    func testArgonFiveHourBucketDoesNotOverrideItsWeeklyQuota() {
        let lines = AntigravityUsageMapper.parseQuotaSummaries([summary(buckets: """
        {"bucketId":"test-session","window":"5h","remainingFraction":0},
        {"bucketId":"test-weekly","window":"weekly","remainingFraction":0.5}
        """)])
        XCTAssertEqual(lines?.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(lines?.first { $0.label == "Argon Weekly" }, .progress(
            label: "Argon Weekly", used: 50, limit: 100, format: .percent,
            resetsAt: nil, periodDurationMs: MetricPeriod.weekMs
        ))
    }

    func testArgonOnlySummaryUsesWeeklyPeriodAndPreservesZeroRemaining() {
        let data = Data(#"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"test-id","window":"weekly","remainingFraction":0,"disabled":false}]}]}"#.utf8)
        let lines = AntigravityUsageMapper.parseQuotaSummaries([data])
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(lines?.first, .progress(
            label: "Argon Weekly", used: 100, limit: 100, format: .percent,
            resetsAt: nil, periodDurationMs: MetricPeriod.weekMs
        ))
    }

    func testArgonWTUWeeklyBucketParsesBareAndWrapped() throws {
        let group = """
        {"displayName":"Gemini 4 Argon",
         "description":"For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.",
         "buckets":[{"bucketId":"gemini-argon-wtu-weekly","displayName":"Gemini 4 Argon Weekly Limit",
                     "window":"weekly","remainingFraction":1.0,"resetTime":"2026-10-22T23:24:33Z"}]}
        """
        let reset = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-10-22T23:24:33Z"))
        let expected = MetricLine.progress(
            label: "Argon Weekly", used: 0, limit: 100, format: .percent,
            resetsAt: reset, periodDurationMs: MetricPeriod.weekMs
        )
        for json in ["{\"groups\":[\(group)]}", "{\"response\":{\"groups\":[\(group)]}}"] {
            XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummaries([Data(json.utf8)]), [expected])
        }
    }

    func testMalformedGroupNameDoesNotInvalidateSharedBuckets() {
        let data = Data(#"{"groups":[{"displayName":42,"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#.utf8)
        let lines = AntigravityUsageMapper.parseQuotaSummaries([data])
        XCTAssertEqual(lines?.map(\.label), ["Session"])
    }
}
