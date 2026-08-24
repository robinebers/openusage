import XCTest
@testable import OpenUsage

/// Covers the single-instance guard's decision logic (issue #635): given our PID and the PIDs of
/// running apps sharing our bundle id, decide which instance we should yield to (lowest-PID-wins), or
/// `nil` to keep running. The live `NSRunningApplication` query and the activate/terminate handoff are
/// thin glue over this pure function and aren't unit-testable (they need a second running process).
@MainActor
final class SingleInstanceGuardTests: XCTestCase {
    func testOnlyTheLowestRunningPIDOwnsTheInstance() {
        let scenarios: [(name: String, running: [pid_t], expected: pid_t?)] = [
            ("solo launch", [42], nil),
            ("empty workspace", [], nil),
            ("lower PID owns the instance", [7, 42], 7),
            ("lowest of several PIDs owns the instance", [20, 9, 42], 9),
            ("higher PID yields to us", [42, 99], nil)
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: scenario.running),
                scenario.expected,
                scenario.name
            )
        }
    }

    /// The headline regression test for the reboot race (cubic P1 / Bugbot): two launches that both
    /// observe both PIDs must resolve to *exactly one* survivor — never zero (both terminate) and
    /// never two. With lowest-PID-wins, the higher-PID launch yields and the lower-PID launch keeps
    /// running.
    func testSimultaneousLaunchLeavesExactlyOneSurvivor() {
        let both: [pid_t] = [100, 101]
        let lowerYieldsTo = SingleInstanceGuard.instanceToYieldTo(myPID: 100, runningPIDs: both)
        let higherYieldsTo = SingleInstanceGuard.instanceToYieldTo(myPID: 101, runningPIDs: both)

        XCTAssertNil(lowerYieldsTo)            // pid 100 keeps running
        XCTAssertEqual(higherYieldsTo, 100)    // pid 101 yields to it
    }
}
