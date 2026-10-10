import XCTest
@testable import OpenUsage

@MainActor
final class KeychainEnablementTests: XCTestCase {
    func testEnablingProviderAuthorizesOnlyTheNextAttemptEvenIfWakeLoopGetsThereFirst() async {
        let runtime = Runtime()
        let suite = "KeychainEnablementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: []),
            providers: [runtime], defaults: defaults
        )
        store.requestKeychainInteraction(true, for: runtime.provider.id)
        await store.refreshAll()
        XCTAssertEqual(runtime.interactions, [true])
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.interactions, [true, false])
    }

    func testTurningProviderOffCancelsUnconsumedPermission() async {
        let runtime = Runtime()
        let suite = "KeychainEnablementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: []),
            providers: [runtime], defaults: defaults
        )
        store.requestKeychainInteraction(true, for: runtime.provider.id)
        store.requestKeychainInteraction(false, for: runtime.provider.id)
        await store.refreshAll()
        XCTAssertEqual(runtime.interactions, [false])
    }

    private final class Runtime: ProviderRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let widgetDescriptors: [WidgetDescriptor] = []
        var interactions: [Bool] = []
        func refresh() async -> ProviderSnapshot {
            interactions.append(await loadOffMainActor { KeychainAccessContext.allowsInteraction })
            return .make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
        }
    }
}
