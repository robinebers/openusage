import XCTest
@testable import OpenUsage

final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    func testWindowAlreadyResetReturnsNil() {
        let past = now.addingTimeInterval(-60)
        XCTAssertNil(Pace.evaluate(used: 50, limit: 100, resetsAt: past, periodDuration: week, now: now))
        XCTAssertNil(Pace.evaluate(used: 50, limit: 100, resetsAt: now, periodDuration: week, now: now))
    }

    private func pacedData(
        used: Double,
        elapsed: Double = 0.5,
        period: TimeInterval? = nil,
        displayMode: WidgetDisplayMode = .used
    ) -> WidgetData {
        let period = period ?? week
        var data = WidgetData(title: "Weekly", kind: .percent,
                              used: used, limit: 100, displayMode: displayMode)
        data.resetsAt = resetsAt(elapsed: elapsed, period: period)
        data.periodDurationMs = Int(period * 1000)
        return data
    }

    func testNoPaceVerdictWithoutAResetWindow() {
        var data = WidgetData(title: "Credits", kind: .dollars,
                              used: 12, limit: 20)
        XCTAssertEqual(data.meterState(now: now), .unpaced)
        data.resetsAt = now.addingTimeInterval(week)
        XCTAssertEqual(data.meterState(now: now), .unpaced)
    }

    func testThePaceVerdictPicksTheMeterState() {
        XCTAssertEqual(pacedData(used: 30).meterState(now: now), .healthy)
        XCTAssertEqual(pacedData(used: 44).meterState(now: now), .healthy)
        XCTAssertEqual(pacedData(used: 46).meterState(now: now), .closeToLimit)
        XCTAssertEqual(pacedData(used: 60).meterState(now: now), .runningOut)
        XCTAssertEqual(pacedData(used: 50.2).meterState(now: now), .runningOut)
    }

    func testZeroUsageHasNoPaceState() {
        XCTAssertEqual(pacedData(used: 0).meterState(now: now), .unpaced)
    }

    func testSpentOutranksThePaceVerdict() {
        XCTAssertEqual(pacedData(used: 100).meterState(now: now), .spent)
        let nearlyEmpty = WidgetData(title: "Credits", kind: .dollars,
                                     used: 99.999, limit: 100)
        XCTAssertEqual(nearlyEmpty.meterState(now: now), .spent)
        let withHeadroom = WidgetData(title: "Credits", kind: .dollars,
                                      used: 99.0, limit: 100)
        XCTAssertEqual(withHeadroom.meterState(now: now), .unpaced)

        var data = WidgetData(title: "Weekly", kind: .percent,
                              used: 99.6, limit: 100)
        data.resetsAt = resetsAt(elapsed: 0.997, period: week)
        data.periodDurationMs = Int(week * 1000)
        XCTAssertEqual(data.meterState(now: now), .spent)
    }

    func testProjectionAtOrRoundedToLimitIsRunningOut() {
        for used in [49.8, 50] {
            XCTAssertEqual(pacedData(used: used).meterState(now: now), .runningOut, "\(used)% used")
        }
    }

    func testSmallButRealCushionStaysAmber() {
        XCTAssertEqual(pacedData(used: 49).meterState(now: now), .closeToLimit)
    }

    func testPlentyRemainingSuppressesFalseRunOutFlame() {
        let session: TimeInterval = 5 * 3600
        let elapsed = 240 / session
        let data = pacedData(used: 2, elapsed: elapsed, period: session)
        XCTAssertEqual(data.meterState(now: now), .unpaced)
    }

    func testOnePercentAtProjectionGateDoesNotBecomeRed() {
        let session: TimeInterval = 5 * 3600
        XCTAssertEqual(pacedData(used: 1, elapsed: 0.01, period: session).meterState(now: now), .unpaced)
    }

    func testRunOutFlameShowsOnceFivePercentUsedDespiteHighRemaining() {
        let session: TimeInterval = 5 * 3600
        let elapsed = 240 / session
        let data = pacedData(used: 6, elapsed: elapsed, period: session)
        guard case .runningOut = data.meterState(now: now) else {
            return XCTFail("expected runningOut when burning fast with ≥5% used")
        }
    }

    func testPaceProjectionWaitsUntilWindowHasMateriallyStarted() {
        let session: TimeInterval = 5 * 3600
        let elapsed = 60 / session
        let reset = resetsAt(elapsed: elapsed, period: session)
        XCTAssertNil(Pace.evaluate(used: 1, limit: 100, resetsAt: reset, periodDuration: session, now: now))
    }
}
