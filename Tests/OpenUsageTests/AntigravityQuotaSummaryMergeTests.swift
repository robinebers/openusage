import XCTest
@testable import OpenUsage

/// Covers merging `RetrieveUserQuotaSummary` bodies from both Cloud Code hosts and the completeness
/// check that lets a refresh skip the second host.
final class AntigravityQuotaSummaryMergeTests: XCTestCase {
    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = line else { return nil }
        return used
    }

    private let completeJSON = #"{"response":{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1},{"bucketId":"gemini-weekly","remainingFraction":1},{"bucketId":"3p-5h","remainingFraction":1},{"bucketId":"3p-weekly","remainingFraction":1}]}]}}"#

    func testMergedSummariesTakeFirstUsableBucketPerID() {
        let first = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h"},{"bucketId":"3p-5h","remainingFraction":0.5}]}]}"#
        let second = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75},{"bucketId":"3p-5h","remainingFraction":0.1}]}]}"#
        let lines = AntigravityUsageMapper.parseQuotaSummaries([Data(first.utf8), Data("not json".utf8), Data(second.utf8)])
        XCTAssertEqual(lines?.map(\.label), ["Session", "Claude"])
        XCTAssertEqual(lines?.map { used($0) }, [25, 50])
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummaries([Data("{}".utf8)]))
    }

    func testMergedSummariesTakeArgonFromTheFirstBodyThatHasIt() {
        let argon = { (fraction: Double) in
            #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":\#(fraction)}]}]}"#
        }
        let lines = AntigravityUsageMapper.parseQuotaSummaries([Data(argon(0.6).utf8), Data(argon(0.1).utf8)])
        XCTAssertEqual(lines?.map(\.label), ["Argon Weekly"], "two hosts' Argon groups must not read as an ambiguous bucket")
        XCTAssertEqual(lines?.map { used($0) }, [40])
    }

    func testIsCompleteSummaryNeedsAllFourUsableBuckets() {
        XCTAssertTrue(AntigravityUsageMapper.isCompleteSummary(Data(completeJSON.utf8)))
        let missingWeekly = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1},{"bucketId":"3p-5h","remainingFraction":1},{"bucketId":"3p-weekly","remainingFraction":1}]}]}"#
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(Data(missingWeekly.utf8)))
        let noFraction = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1},{"bucketId":"gemini-weekly"},{"bucketId":"3p-5h","remainingFraction":1},{"bucketId":"3p-weekly","remainingFraction":1}]}]}"#
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(Data(noFraction.utf8)))
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(Data("not json".utf8)))
        let weeklyInArgon = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1},{"bucketId":"3p-5h","remainingFraction":1},{"bucketId":"3p-weekly","remainingFraction":1}]},{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1}]}]}"#
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(Data(weeklyInArgon.utf8)),
                       "a shared bucket id inside the Argon group is not a usable shared-pool window")
    }
}
