import XCTest
@testable import OpenUsage

/// Turning a provider on is the user asking to connect it, so that one refresh may prompt. A quiet
/// background refresh already in flight must not swallow the request.
@MainActor
final class KeychainEnablementTests: XCTestCase {
    func testInteractiveRequestDuringQuietRefreshRunsOnceAfterIt() async {
        let runtime = Runtime()
        let store = makeStore(runtime)
        let quiet = Task { await store.refresh(providerID: "test") }
        await runtime.started.wait()

        let request = await store.refresh(providerID: "test", force: true, allowsKeychainInteraction: true)
        XCTAssertEqual(request, .skipped)
        runtime.release()
        _ = await quiet.value
        await runtime.waitForRefreshes(2)

        XCTAssertEqual(runtime.interactions, [false, true])
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.interactions, [false, true, false], "the permission never carries to later polls")
    }

    func testTurningProviderOffDropsQueuedInteractiveRequest() async {
        let runtime = Runtime()
        var enabled = true
        let store = makeStore(runtime, isEnabled: { enabled })
        let quiet = Task { await store.refresh(providerID: "test") }
        await runtime.started.wait()
        await store.refresh(providerID: "test", force: true, allowsKeychainInteraction: true)
        enabled = false
        runtime.release()
        _ = await quiet.value
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(runtime.interactions, [false])
    }

    func testInteractiveRequestDuringInteractiveRefreshIsNotRepeated() async {
        let runtime = Runtime()
        let store = makeStore(runtime)
        let first = Task { await store.refresh(providerID: "test", force: true, allowsKeychainInteraction: true) }
        await runtime.started.wait()
        await store.refresh(providerID: "test", force: true, allowsKeychainInteraction: true)
        runtime.release()
        _ = await first.value
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(runtime.interactions, [true], "a second dialog for the same request would be noise")
    }

    private func makeStore(_ runtime: Runtime, isEnabled: @escaping @MainActor () -> Bool = { true }) -> WidgetDataStore {
        let suite = "KeychainEnablementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: []),
            providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults,
            isProviderEnabled: { _ in isEnabled() }
        )
    }

    /// Holds its first refresh open until `release()`, so a test can race a second request against it.
    private final class Runtime: ProviderRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let widgetDescriptors: [WidgetDescriptor] = []
        let started = Signal()
        private let gate = Signal()
        private var held = false
        var interactions: [Bool] = []

        func refresh() async -> ProviderSnapshot {
            interactions.append(await loadOffMainActor { KeychainAccessContext.allowsInteraction })
            if !held {
                held = true
                started.fire()
                await gate.wait()
            }
            return .make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
        }

        func release() { gate.fire() }

        func waitForRefreshes(_ count: Int) async {
            for _ in 0..<200 where interactions.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    /// A one-shot latch: `wait()` returns once `fire()` has been called, before or after.
    @MainActor
    private final class Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fire() {
            fired = true
            waiters.forEach { $0.resume() }
            waiters = []
        }

        func wait() async {
            guard !fired else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
