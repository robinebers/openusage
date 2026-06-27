import XCTest
@testable import OpenUsage

final class ClaudeRefreshFailureGateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "claude.refreshGate.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A mutable fingerprint box so a test can simulate an external `claude` re-login changing the creds.
    private final class FingerprintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClaudeCredentialFingerprint
        init(_ value: ClaudeCredentialFingerprint) { self.value = value }
        var current: ClaudeCredentialFingerprint {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func set(_ value: ClaudeCredentialFingerprint) {
            lock.lock(); defer { lock.unlock() }; self.value = value
        }
    }

    private func makeGate(_ box: FingerprintBox) -> ClaudeRefreshFailureGate {
        ClaudeRefreshFailureGate(
            defaults: defaults,
            storageKey: "gate.state",
            currentFingerprint: { box.current }
        )
    }

    func testNoBlockAllowsAttempt() {
        let gate = makeGate(FingerprintBox(.init(tokenHash: "a")))
        XCTAssertTrue(gate.shouldAttempt(now: Date()))
        XCTAssertNil(gate.currentBlockStatus(now: Date()))
    }

    func testTransientExponentialBackoffCappedAtSixHours() {
        let gate = makeGate(FingerprintBox(.init(tokenHash: "a")))
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // 1st failure → 5 min.
        gate.recordTransientFailure(now: t0)
        guard case .transient(let until1, let failures1)? = gate.currentBlockStatus(now: t0) else {
            return XCTFail("expected transient block")
        }
        XCTAssertEqual(failures1, 1)
        XCTAssertEqual(until1.timeIntervalSince(t0), 5 * 60, accuracy: 1)

        // 2nd → 10 min, 3rd → 20 min (after the prior window elapses so the gate allows the attempt).
        gate.recordTransientFailure(now: until1)
        guard case .transient(let until2, _)? = gate.currentBlockStatus(now: until1) else {
            return XCTFail("expected transient block")
        }
        XCTAssertEqual(until2.timeIntervalSince(until1), 10 * 60, accuracy: 1)

        // Drive many failures and confirm the cap.
        var moment = until2
        for _ in 0..<20 {
            gate.recordTransientFailure(now: moment)
            guard case .transient(let until, _)? = gate.currentBlockStatus(now: moment) else {
                return XCTFail("expected transient block")
            }
            moment = until
        }
        guard case .transient(let cappedUntil, _)? = gate.currentBlockStatus(now: moment.addingTimeInterval(-1)) else {
            return XCTFail("expected transient block")
        }
        // The last recorded window must be exactly the 6h cap.
        gate.recordTransientFailure(now: cappedUntil)
        guard case .transient(let finalUntil, _)? = gate.currentBlockStatus(now: cappedUntil) else {
            return XCTFail("expected transient block")
        }
        XCTAssertEqual(finalUntil.timeIntervalSince(cappedUntil), 6 * 60 * 60, accuracy: 1)
    }

    func testTransientBlockExpiresByTime() {
        let gate = makeGate(FingerprintBox(.init(tokenHash: "a")))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTransientFailure(now: t0)

        XCTAssertFalse(gate.shouldAttempt(now: t0.addingTimeInterval(60)))
        // After the 5-min window the gate allows an attempt and reports no active block.
        XCTAssertTrue(gate.shouldAttempt(now: t0.addingTimeInterval(5 * 60 + 1)))
        XCTAssertNil(gate.currentBlockStatus(now: t0.addingTimeInterval(5 * 60 + 1)))
    }

    func testTerminalNeverExpiresByTimeAndTransientDoesNotDowngrade() {
        let box = FingerprintBox(.init(tokenHash: "a"))
        let gate = makeGate(box)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTerminalAuthFailure(reason: "invalid_grant", now: t0)

        // Even a year later, terminal stays blocked (creds unchanged).
        let muchLater = t0.addingTimeInterval(365 * 24 * 60 * 60)
        guard case .terminal(let reason, _)? = gate.currentBlockStatus(now: muchLater) else {
            return XCTFail("expected terminal block")
        }
        XCTAssertEqual(reason, "invalid_grant")
        XCTAssertFalse(gate.shouldAttempt(now: muchLater))

        // A later transient failure must NOT downgrade the terminal block to a self-clearing transient.
        gate.recordTransientFailure(now: muchLater)
        guard case .terminal? = gate.currentBlockStatus(now: muchLater.addingTimeInterval(10 * 60 * 60)) else {
            return XCTFail("expected terminal block to survive a transient failure")
        }
    }

    func testChangedFingerprintUnblocksTerminal() {
        let box = FingerprintBox(.init(tokenHash: "a"))
        let gate = makeGate(box)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTerminalAuthFailure(reason: "invalid_grant", now: t0)
        XCTAssertFalse(gate.shouldAttempt(now: t0))

        // External `claude` re-login rotates the credential → fingerprint changes → unblock (after the
        // 15s recheck throttle elapses).
        box.set(.init(tokenHash: "b"))
        XCTAssertTrue(gate.shouldAttempt(now: t0.addingTimeInterval(16)))
        XCTAssertNil(gate.currentBlockStatus(now: t0.addingTimeInterval(16)))
    }

    func testChangedFingerprintUnblocksTransient() {
        let box = FingerprintBox(.init(tokenHash: "a"))
        let gate = makeGate(box)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTransientFailure(now: t0)
        XCTAssertFalse(gate.shouldAttempt(now: t0.addingTimeInterval(16)))

        box.set(.init(tokenHash: "b"))
        XCTAssertTrue(gate.shouldAttempt(now: t0.addingTimeInterval(32)))
    }

    func testUnchangedFingerprintStaysBlocked() {
        let box = FingerprintBox(.init(tokenHash: "a"))
        let gate = makeGate(box)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTerminalAuthFailure(reason: "invalid_grant", now: t0)

        // Many rechecks, creds never change → stays blocked.
        XCTAssertFalse(gate.shouldAttempt(now: t0.addingTimeInterval(20)))
        XCTAssertFalse(gate.shouldAttempt(now: t0.addingTimeInterval(40)))
    }

    func testRecheckThrottledToOncePer15Seconds() {
        let box = FingerprintBox(.init(tokenHash: "a"))
        let gate = makeGate(box)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTerminalAuthFailure(reason: "invalid_grant", now: t0)

        // Change the creds, but query within 15s of the failure's recheck stamp → throttled, stays blocked.
        box.set(.init(tokenHash: "b"))
        XCTAssertFalse(gate.shouldAttempt(now: t0.addingTimeInterval(5)))
        XCTAssertFalse(gate.shouldAttempt(now: t0.addingTimeInterval(10)))
        // Past the throttle window the changed fingerprint is observed → unblocked.
        XCTAssertTrue(gate.shouldAttempt(now: t0.addingTimeInterval(16)))
    }

    func testRecordSuccessClearsBlock() {
        let gate = makeGate(FingerprintBox(.init(tokenHash: "a")))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.recordTerminalAuthFailure(reason: "invalid_grant", now: t0)
        XCTAssertNotNil(gate.currentBlockStatus(now: t0))

        gate.recordSuccess()
        XCTAssertNil(gate.currentBlockStatus(now: t0))
        XCTAssertTrue(gate.shouldAttempt(now: t0))
    }

    func testUserDefaultsRoundTripAcrossInstances() {
        let box = FingerprintBox(.init(tokenHash: "a"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // First instance records a terminal block.
        makeGate(box).recordTerminalAuthFailure(reason: "invalid_grant", now: t0)

        // A fresh instance (simulating an app relaunch) reading the same suite still sees the block.
        let reloaded = makeGate(box)
        guard case .terminal(let reason, _)? = reloaded.currentBlockStatus(now: t0.addingTimeInterval(1000)) else {
            return XCTFail("terminal block should survive a fresh gate instance")
        }
        XCTAssertEqual(reason, "invalid_grant")
    }
}
