import Foundation
import XCTest
@testable import OpenUsage

/// A container reports through the sink and defaults it was given and nowhere else: an account change
/// drives a refresh whose outcome lands in the injected defaults, and the daily ping lands in the
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
        let recorder = container.telemetry
        for _ in 0..<200 where recorder.providerCounters().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let counter = try XCTUnwrap(recorder.providerCounters()["claude"], "the failed fetch is counted under the provider kind")
        XCTAssertEqual(counter.failure, 1)
        XCTAssertEqual(counter.manual, 1, "a new account's first refresh is forced")
        XCTAssertNil(recorder.providerCounters()[claude.cardID], "counters are kind-scoped, never per account")

        container.telemetry.tick()
        let active = sink.events(named: "app_daily_active")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0]["install_id"] as? String, recorder.installID)
        XCTAssertEqual(active[0]["enabled_providers"] as? [String], ["claude"])
    }
}
