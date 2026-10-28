import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class ContainerTelemetryTests: XCTestCase {
    func testAccountChangesRecordThroughTheInjectedSinkAndStore() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let sink = RecordingTelemetrySink()
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, telemetry: sink)

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
