import Foundation
import os
import XCTest
@testable import OpenUsage

@MainActor
final class RefreshTimeoutTests: XCTestCase {
    func testHungProviderRefreshFailsAndStopsTheSpinner() async {
        let (provider, descriptor) = makeProvider()
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [descriptor])
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, timeout: 0.05)

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty, "the spinner must stop when the deadline wins")
        XCTAssertEqual(store.errorMessage(for: provider.id)?.hasPrefix("Refresh timed out after"), true)
        let next = await store.refresh(providerID: provider.id)
        XCTAssertEqual(next, .backedOff)
    }

    func testHungProviderRefreshIsCancelledWhenTheDeadlineWins() async {
        let (provider, descriptor) = makeProvider()
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [descriptor])
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, timeout: 0.05)

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .failed)
        let cancelled = await waitUntil { runtime.wasCancelled }
        XCTAssertTrue(cancelled, "a refresh the store gave up on must be cancelled, or the hung work runs forever")
    }

    func testRefreshInsideTheDeadlineStillSucceeds() async {
        let (provider, descriptor) = makeProvider()
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)]
            )
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, timeout: 0.05)

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertEqual(store.data(for: descriptor).used, 42)
    }

    func testAHungHourlyReadDoesNotHoldUpTheNextPassForAnotherAccount() async throws {
        let clock = TestClock(Date())
        let vault = StallingVault()
        let account = Account(kind: .claude, label: "Work")
        try vault.save(.oauth(OAuthTokens(accessToken: "token", refreshToken: "refresh")), for: account.id)
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8))
        }
        let claude = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        let (provider, descriptor) = makeProvider()
        let other = StubRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [], refreshedAt: clock.now)
        )
        let store = WidgetDataStore.forTesting([claude, other], defaults: isolatedDefaults(), now: { clock.now }, providerRefreshTimeout: 0.05)
        await store.refreshAll()
        XCTAssertNotNil(store.snapshots[claude.provider.id])
        XCTAssertEqual(other.refreshCount, 1)

        vault.stall()
        addTeardownBlock { vault.release() }
        Task {
            clock.set(clock.now.addingTimeInterval(RefreshSetting.interval / 2))
            await store.refreshHourlyReads()
            clock.set(clock.now.addingTimeInterval(RefreshSetting.interval / 2))
            await store.refreshAll()
        }

        let refreshed = await waitUntil { other.refreshCount == 2 }
        XCTAssertTrue(refreshed, "a Claude hourly read stuck on its Keychain item must not hold up the next pass")
    }

    func testAPassJoinsAStuckKeychainReadInsteadOfStartingAnother() async throws {
        let vault = StallingVault()
        let account = Account(kind: .claude, label: "Work")
        try vault.save(.oauth(OAuthTokens(accessToken: "token", refreshToken: "refresh")), for: account.id)
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8))
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        vault.stall()
        let passes = [Task { await runtime.refresh() }, Task { await runtime.refresh() }]
        _ = await waitUntil { vault.loads > 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vault.loads, 1, "a stuck Keychain read holds a thread, so a second pass must wait on it, not start another")

        vault.release()
        for pass in passes {
            let snapshot = try await pass.value.get()
            XCTAssertFalse(snapshot.lines.isEmpty)
        }
    }

    private func makeProvider() -> (Provider, WidgetDescriptor) {
        let provider = Provider(id: "test", kind: .codex)
        let descriptor = WidgetDescriptor(
            provider: provider,
            key: "session",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100)
        )
        return (provider, descriptor)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: ProviderRuntime,
        timeout: TimeInterval
    ) -> WidgetDataStore {
        let defaults = isolatedDefaults()
        return WidgetDataStore.forTesting([runtime], defaults: defaults, providerRefreshTimeout: timeout)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

}

/// A vault whose reads block once stalled, the way a Keychain read waits on a prompt nobody answers.
final class StallingVault: CredentialVault, @unchecked Sendable {
    private let stored = InMemoryCredentialVault()
    private let stalled = OSAllocatedUnfairLock(initialState: false)
    private let loadCount = OSAllocatedUnfairLock(initialState: 0)
    private let gate = DispatchGroup()

    var loads: Int { loadCount.withLock { $0 } }

    func stall() {
        gate.enter()
        stalled.withLock { $0 = true }
    }

    func release() {
        stalled.withLock { $0 = false }
        gate.leave()
    }

    func load(_ id: UUID) throws -> AccountCredential? {
        loadCount.withLock { $0 += 1 }
        if stalled.withLock({ $0 }) { gate.wait() }
        return try stored.load(id)
    }

    func save(_ credential: AccountCredential, for id: UUID) throws { try stored.save(credential, for: id) }
    func update(_ credential: AccountCredential, for id: UUID) throws { try stored.update(credential, for: id) }
    func delete(_ id: UUID) throws { try stored.delete(id) }
}
