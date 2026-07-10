import XCTest
@testable import OpenUsage

/// Covers the per-provider refresh gate. Only one provider request may run at a time, but an explicit
/// force that arrives after the active request loaded its credentials must survive as one fresh follow-up.
@MainActor
final class RefreshCoalescingTests: XCTestCase {
    func testCancellingJoinedCallerReturnsPromptlyWithoutCancellingOwner() async {
        let fixture = makeFixture(snapshots: [successSnapshot(used: 40)])
        let firstStarted = expectation(description: "original refresh started")
        let joinedFinished = expectation(description: "cancelled joined caller returned")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let joinedReturned = MutableFlag(value: false)
        let joined = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id)
            joinedReturned.value = true
            joinedFinished.fulfill()
            return outcome
        }
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(joinedReturned.value, "the caller must be registered behind the active owner")

        joined.cancel()
        await fulfillment(of: [joinedFinished], timeout: 1)

        let joinedOutcome = await joined.value
        XCTAssertTrue(joinedOutcome == .skipped)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.contains(testProvider.id))
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
    }

    func testCancelledOwnerHandsQueuedForceToFreshTask() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "Cancelled owner result."),
                successSnapshot(used: 80),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "handed-off forced refresh started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }
        var telemetry: [(outcome: WidgetDataStore.RefreshOutcome, manual: Bool)] = []
        fixture.store.onRefreshOutcome = { _, outcome, _, manual in
            telemetry.append((outcome, manual))
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let forcedReturned = MutableFlag(value: false)
        let forced = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            forcedReturned.value = true
            return outcome
        }
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(forcedReturned.value)

        original.cancel()
        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)

        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertFalse(forcedReturned.value)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertEqual(fixture.runtime.startedWhileCancelled, [false, false])

        fixture.runtime.resumeNext()
        let forcedOutcome = await forced.value
        XCTAssertTrue(forcedOutcome == .refreshed)
        XCTAssertNil(fixture.store.errorMessage(for: testProvider.id))
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertEqual(telemetry.count, 1)
        XCTAssertTrue(telemetry.first?.outcome == .refreshed)
        XCTAssertTrue(telemetry.first?.manual == true)
    }

    func testCancellingOnlyForcedWaiterWithdrawsItsFollowUp() async {
        let fixture = makeFixture(snapshots: [successSnapshot(used: 40)])
        let firstStarted = expectation(description: "original refresh started")
        let forcedFinished = expectation(description: "cancelled force returned")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let forced = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            forcedFinished.fulfill()
            return outcome
        }
        await Task.yield()
        await Task.yield()

        forced.cancel()
        // Resume the owner immediately, before the cancellation cleanup task can hop back to MainActor.
        // The synchronous cancellation flag must still prevent this owner from claiming the force.
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        await fulfillment(of: [forcedFinished], timeout: 1)
        let forcedOutcome = await forced.value

        XCTAssertTrue(forcedOutcome == .skipped)
        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 1, "a cancelled sole force must not leave orphaned work")
    }

    func testCancellingClaimedForceAndOwnerDoesNotRestoreOwnerlessWork() async {
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 40), successSnapshot(used: 80)]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "forced follow-up started")
        let forcedFinished = expectation(description: "cancelled force returned")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forced = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            forcedFinished.fulfill()
            return outcome
        }
        await Task.yield()
        await Task.yield()

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)

        // The follow-up already claimed this waiter's force. Cancelling the waiter must still revoke
        // that provenance; cancelling the owner afterward cannot restore it as independent work.
        forced.cancel()
        await fulfillment(of: [forcedFinished], timeout: 1)
        original.cancel()
        fixture.runtime.resumeNext()

        let forcedOutcome = await forced.value
        let originalOutcome = await original.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(forcedOutcome == .skipped)
        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "no live requester remains for a third fetch")
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testCancellingOwnerAfterClaimedForceSucceedsDoesNotReplayCompletedClaim() async {
        let fixture = makeFixture(
            snapshots: [
                successSnapshot(used: 20),
                successSnapshot(used: 80),
                successSnapshot(used: 95),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "forced follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
            if count == 3 {
                // Keep a regressed implementation from hanging the test on its erroneous replay.
                Task {
                    await Task.yield()
                    fixture.runtime.resumeNext()
                }
            }
        }

        var original: Task<WidgetDataStore.RefreshOutcome, Never>?
        fixture.store.onRefreshOutcome = { _, outcome, _, force in
            // Cancellation lands after the forced request committed its successful snapshot but before
            // the owner resumes from performRefresh. The consumed claim is already satisfied.
            if force, outcome == .refreshed, fixture.runtime.refreshCount == 2 {
                original?.cancel()
            }
        }

        original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forced = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await Task.yield()

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)
        fixture.runtime.resumeNext()

        let originalOutcome = await original?.value
        let forcedOutcome = await forced.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertTrue(forcedOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "completed forced work must not be replayed")
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testCancelledClaimedEnablementIntentIsHandedOff() async {
        let fixture = makeFixture(
            snapshots: [
                successSnapshot(used: 20),
                successSnapshot(used: 40),
                successSnapshot(used: 90),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "enablement follow-up started")
        let handedOffStarted = expectation(description: "enablement intent handed off")
        let handedOffFinished = expectation(description: "handed-off refresh finished")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
            if count == 3 { handedOffStarted.fulfill() }
        }
        fixture.store.onRefreshOutcome = { _, outcome, _, force in
            if outcome == .refreshed, force, fixture.runtime.refreshCount == 3 {
                handedOffFinished.fulfill()
            }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        fixture.store.prepareProviderEnablementRefresh(for: testProvider.id)
        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)

        // Unlike waiter-backed intent, an enablement action remains meaningful without a waiting task.
        original.cancel()
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .skipped)

        await fulfillment(of: [handedOffStarted], timeout: 1)
        fixture.runtime.resumeNext()
        await fulfillment(of: [handedOffFinished], timeout: 1)

        XCTAssertEqual(fixture.runtime.refreshCount, 3)
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 90))
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testNonForcedCallerJoinsActiveRefreshBeforeReturning() async {
        let fixture = makeFixture(snapshots: [successSnapshot(used: 40)])
        let firstStarted = expectation(description: "original refresh started")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let joinedReturned = MutableFlag(value: false)
        let joined = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id)
            joinedReturned.value = true
            return outcome
        }
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(joinedReturned.value)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        // The periodic-style caller was held until the active request produced current data; it did not
        // start a duplicate and could not continue into notification evaluation against the old snapshot.
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let joinedOutcome = await joined.value

        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertTrue(joinedOutcome == .refreshed)
        XCTAssertTrue(joinedReturned.value)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
    }

    func testConcurrentForcesCoalesceIntoOnePostFlightRefresh() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "The old key was rejected."),
                successSnapshot(used: 80),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "forced follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }
        var telemetry: [(outcome: WidgetDataStore.RefreshOutcome, manual: Bool)] = []
        fixture.store.onRefreshOutcome = { _, outcome, _, manual in
            telemetry.append((outcome, manual))
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        // Model an API-key save and a second click while the request that loaded the old key is suspended.
        // Both callers must join one queued follow-up rather than disappearing or starting overlapping I/O.
        let forcedA = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        let forcedB = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.contains(testProvider.id))

        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let forcedAOutcome = await forcedA.value
        let forcedBOutcome = await forcedB.value

        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertTrue(forcedAOutcome == .refreshed)
        XCTAssertTrue(forcedBOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "a force burst must produce exactly one follow-up")
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
        XCTAssertNil(fixture.store.errorMessage(for: testProvider.id))
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertEqual(telemetry.count, 2)
        XCTAssertTrue(telemetry[0].outcome == .failed)
        XCTAssertFalse(telemetry[0].manual)
        XCTAssertTrue(telemetry[1].outcome == .refreshed)
        XCTAssertTrue(telemetry[1].manual)
    }

    func testForceDuringForcedFollowUpQueuesOneSequentialThirdRefresh() async {
        let fixture = makeFixture(
            snapshots: [
                successSnapshot(used: 20),
                successSnapshot(used: 60),
                .error(provider: testProvider, message: "Newest credential was rejected."),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let secondStarted = expectation(description: "first forced follow-up started")
        let thirdStarted = expectation(description: "second forced follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { secondStarted.fulfill() }
            if count == 3 { thirdStarted.fulfill() }
        }
        var waiterReturnCount = 0

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forcedA = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            waiterReturnCount += 1
            return outcome
        }
        await Task.yield()

        fixture.runtime.resumeNext()
        await fulfillment(of: [secondStarted], timeout: 1)
        let forcedB = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            waiterReturnCount += 1
            return outcome
        }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertEqual(waiterReturnCount, 0)

        fixture.runtime.resumeNext()
        await fulfillment(of: [thirdStarted], timeout: 1)
        XCTAssertEqual(fixture.runtime.refreshCount, 3)
        XCTAssertEqual(fixture.runtime.maximumConcurrentRefreshCount, 1)
        XCTAssertEqual(waiterReturnCount, 0, "both force callers wait for the newest queued outcome")

        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let forcedAOutcome = await forcedA.value
        let forcedBOutcome = await forcedB.value

        XCTAssertTrue(originalOutcome == .failed)
        XCTAssertTrue(forcedAOutcome == .failed)
        XCTAssertTrue(forcedBOutcome == .failed)
        XCTAssertEqual(waiterReturnCount, 2)
        XCTAssertEqual(fixture.runtime.refreshCount, 3, "the later force queues exactly one more request")
        XCTAssertEqual(fixture.runtime.maximumConcurrentRefreshCount, 1, "provider requests never overlap")
        XCTAssertEqual(fixture.store.errorMessage(for: testProvider.id), "Newest credential was rejected.")
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 60))
    }

    func testDelayedCredentialForceDoesNotPrequeueOwnerlessFollowUp() async {
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 40), successSnapshot(used: 80)]
        )
        let firstStarted = expectation(description: "original refresh started")
        let credentialRefreshStarted = expectation(description: "credential refresh started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { credentialRefreshStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        // API-key persistence is synchronous, but its forced refresh starts in a Task. Model the owner
        // finishing before that Task registers: saving a key has no separate enablement prequeue, so the
        // owner completes after one request and the delayed force becomes exactly the second request.
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        let credentialRefresh = Task {
            await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [credentialRefreshStarted], timeout: 1)
        fixture.runtime.resumeNext()

        let credentialOutcome = await credentialRefresh.value
        XCTAssertTrue(credentialOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "one credential save must issue one fresh request")
    }

    func testPreparingEnablementDuringRequestQueuesImmediateFollowUp() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "The old request failed."),
                successSnapshot(used: 65),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "enablement follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        // Re-enabling a provider calls this before the wake-driven pass. If the old request later fails,
        // it must not restore a backoff and swallow the user's request for an immediate probe.
        fixture.store.prepareProviderEnablementRefresh(for: testProvider.id)
        fixture.runtime.resumeNext()

        await fulfillment(of: [followUpStarted], timeout: 1)
        fixture.runtime.resumeNext()
        let outcome = await original.value

        XCTAssertTrue(outcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertNil(fixture.store.errorMessage(for: testProvider.id))
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 65))
    }

    func testDisableCancelsQueuedFollowUpAndReleasesWaitingCaller() async {
        let enabled = MutableFlag()
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 25)],
            isEnabled: { enabled.value }
        )
        let firstStarted = expectation(description: "original refresh started")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let joined = Task { await fixture.store.refresh(providerID: testProvider.id) }
        let forced = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await Task.yield()

        enabled.value = false
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let joinedOutcome = await joined.value
        let forcedOutcome = await forced.value

        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertTrue(joinedOutcome == .refreshed, "an ordinary joiner keeps the active request outcome")
        XCTAssertTrue(forcedOutcome == .skipped)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: WidgetDataStore
        let runtime: SuspendedSequenceProviderRuntime
    }

    private var testProvider: Provider {
        Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
    }

    private func makeFixture(
        snapshots: [ProviderSnapshot],
        isEnabled: @escaping @MainActor () -> Bool = { true }
    ) -> Fixture {
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: testProvider.id,
            metricLabel: "Session",
            sample: WidgetData(
                title: "Session",
                icon: testProvider.icon,
                kind: .percent,
                used: 0,
                limit: 100
            )
        )
        let runtime = SuspendedSequenceProviderRuntime(
            provider: testProvider,
            descriptors: [descriptor],
            snapshots: snapshots
        )
        let defaults = UserDefaults(suiteName: "RefreshCoalescingTests.\(UUID().uuidString)")!
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [testProvider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            isProviderEnabled: { _ in isEnabled() }
        )
        return Fixture(store: store, runtime: runtime)
    }

    private func successSnapshot(used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: testProvider.id,
            displayName: testProvider.displayName,
            lines: [sessionLine(used: used)]
        )
    }

    private func sessionLine(used: Double) -> MetricLine {
        .progress(label: "Session", used: used, limit: 100, format: .percent)
    }
}
