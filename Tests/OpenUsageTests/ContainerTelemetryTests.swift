import Foundation
import XCTest
@testable import OpenUsage

/// A container reports through the sink and store it was given and nowhere else: an account change
/// drives a refresh whose outcome lands in the injected store, and the daily ping lands in the
/// injected sink. The PostHog sink is constructed only at the app entry point.
@MainActor
final class ContainerTelemetryTests: XCTestCase {
    func testAccountChangesRecordThroughTheInjectedSinkAndStore() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let sink = RecordingTelemetrySink()
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, telemetry: sink)

        // An API-key credential fails a Claude refresh before any request, so nothing reaches the network.
        let claude = accounts.add(kind: .claude, label: "Home", credential: .apiKey("key"))
        let store = TelemetryStore(defaults: defaults)
        for _ in 0..<200 where store.providerCounters().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let counter = try XCTUnwrap(store.providerCounters()["claude"], "the failed fetch is counted under the provider kind")
        XCTAssertEqual(counter.failure, 1)
        XCTAssertEqual(counter.manual, 1, "a new account's first refresh is forced")
        XCTAssertNil(store.providerCounters()[claude.cardID], "counters are kind-scoped, never per account")

        container.telemetry.tick()
        let active = sink.events(named: "app_daily_active")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0]["install_id"] as? String, store.installID)
        XCTAssertEqual(active[0]["enabled_providers"] as? [String], ["claude"])
    }
}
