import XCTest
@testable import OpenUsage

@MainActor
final class UseItOrLoseItNotificationTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var reset: Date { start.addingTimeInterval(day + 3600) }

    private static let provider = Provider(id: "test", kind: .claude)
    private static let descriptor = WidgetDescriptor(
        provider: provider,
        key: "weekly",
        metricLabel: "Weekly",
        sample: WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
    )

    private func weekly(used: Double, resetsAt: Date? = nil, periodMs: Int? = MetricPeriod.weekMs) -> WidgetData {
        var data = WidgetData(title: "Weekly", kind: .percent, used: used, limit: 100)
        data.resetsAt = resetsAt ?? reset
        data.periodDurationMs = periodMs
        return data
    }

    private final class Recorder {
        var posts: [(idPrefix: String, title: String, subtitle: String, body: String)] = []
    }

    private func evaluator(_ recorder: Recorder) -> QuotaNotificationEvaluator {
        QuotaNotificationEvaluator { idPrefix, title, subtitle, body in
            recorder.posts.append((idPrefix, title, subtitle, body))
            return true
        }
    }

    private func evaluate(
        _ evaluator: QuotaNotificationEvaluator, _ data: WidgetData, at now: Date, isOn: Bool = true
    ) async {
        await evaluator.evaluate(
            [Self.descriptor],
            data: { _ in data },
            isOn: { $0 == .useItOrLoseIt && isOn },
            now: now,
            providerName: { _ in "Claude" }
        )
    }

    func testFiresAtTwentyFourHoursWithOverHalfLeft() {
        let atLead = reset.addingTimeInterval(-day)
        XCTAssertTrue(PaceNotificationLogic.isUnusedNearReset(weekly(used: 49), now: atLead))
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(weekly(used: 49), now: atLead.addingTimeInterval(-1)),
                       "more than 24 hours before the reset")
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(weekly(used: 50), now: atLead),
                       "exactly half left is not over half")
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(weekly(used: 49), now: reset),
                       "the window already reset")
    }

    func testSkipsSessionAndDailyWindows() {
        let soon = reset.addingTimeInterval(-3600)
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(weekly(used: 10, periodMs: MetricPeriod.sessionMs), now: soon))
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(weekly(used: 10, periodMs: MetricPeriod.dayMs), now: soon))
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(weekly(used: 10, periodMs: nil), now: soon))
        XCTAssertTrue(PaceNotificationLogic.isUnusedNearReset(weekly(used: 10, periodMs: MetricPeriod.monthMs), now: soon))
    }

    func testSkipsDollarSpendCaps() {
        var cap = WidgetData(title: "Key Limit", kind: .dollars, used: 20, limit: 100)
        cap.resetsAt = reset
        cap.periodDurationMs = MetricPeriod.monthMs
        XCTAssertFalse(PaceNotificationLogic.isUnusedNearReset(cap, now: reset.addingTimeInterval(-3600)))
    }

    func testFiresOncePerWindowAndReArmsOnTheNextWindow() async {
        let recorder = Recorder()
        let evaluator = evaluator(recorder)
        await evaluate(evaluator, weekly(used: 20), at: start)
        XCTAssertTrue(recorder.posts.isEmpty, "more than 24 hours before the reset")

        await evaluate(evaluator, weekly(used: 20), at: reset.addingTimeInterval(-day))
        XCTAssertEqual(recorder.posts.map(\.idPrefix), ["test.useItOrLoseIt"])
        XCTAssertEqual(recorder.posts.first?.title, "Use It or Lose It")
        XCTAssertEqual(recorder.posts.first?.subtitle, "Claude Weekly")
        XCTAssertEqual(recorder.posts.first?.body, "Over 50% left, resets in under 24 hours.")

        await evaluate(evaluator, weekly(used: 30), at: reset.addingTimeInterval(-3600))
        XCTAssertEqual(recorder.posts.count, 1, "once per reset window")

        let nextReset = reset.addingTimeInterval(7 * day)
        await evaluate(evaluator, weekly(used: 0, resetsAt: nextReset), at: reset.addingTimeInterval(60))
        XCTAssertEqual(recorder.posts.count, 1)
        await evaluate(evaluator, weekly(used: 40, resetsAt: nextReset), at: nextReset.addingTimeInterval(-3600))
        XCTAssertEqual(recorder.posts.count, 2, "a new window re-arms it")
    }

    func testSessionWindowNeverFiresThroughTheEvaluator() async {
        let recorder = Recorder()
        let evaluator = evaluator(recorder)
        let session = weekly(used: 10, periodMs: MetricPeriod.sessionMs)
        await evaluate(evaluator, session, at: start)
        await evaluate(evaluator, session, at: reset.addingTimeInterval(-3600))
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testOffSettingPostsNothing() async {
        let recorder = Recorder()
        let evaluator = evaluator(recorder)
        await evaluate(evaluator, weekly(used: 20), at: start, isOn: false)
        await evaluate(evaluator, weekly(used: 20), at: reset.addingTimeInterval(-3600), isOn: false)
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testColdStartInsideTheLastDayPrimesWithoutFiring() async {
        let recorder = Recorder()
        let evaluator = evaluator(recorder)
        await evaluate(evaluator, weekly(used: 20), at: reset.addingTimeInterval(-3600))
        await evaluate(evaluator, weekly(used: 20), at: reset.addingTimeInterval(-1800))
        XCTAssertTrue(recorder.posts.isEmpty)
    }
}
