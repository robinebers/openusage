import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class ContainerTelemetryTests: XCTestCase {
    func testDailyTelemetryCountsDirectAndMirroredAccountsByProvider() throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        accounts.add(kind: .claude, label: "Home", credential: .apiKey("key-home"))
        accounts.add(kind: .claude, label: "Work", credential: .apiKey("key-work"))
        let hub = CLIProxyHub(url: URL(string: "https://hub.example")!)
        try accounts.addHub(hub, key: "management-key")
        try accounts.mirror([
            HubLogin(id: "a", authIndex: "index-a", provider: "claude", label: "Hub Claude", isOAuth: true, isDisabled: false, chatGPTAccountID: nil),
            HubLogin(id: "b", authIndex: "index-b", provider: "codex", label: "Hub Codex", isOAuth: true, isDisabled: false, chatGPTAccountID: nil)
        ], from: hub.id)
        let sink = RecordingTelemetrySink()
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, telemetry: sink)
        let recorder = container.telemetry

        recorder.tick()
        let active = sink.events(named: "app_daily_active")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0]["install_id"] as? String, recorder.installID)
        XCTAssertEqual(active[0]["enabled_providers"] as? [String], ["claude", "codex"])
        let metricIDs = try XCTUnwrap(active[0]["enabled_metric_ids"] as? [String])
        XCTAssertTrue(metricIDs.contains("claude.session"))
        XCTAssertTrue(metricIDs.allSatisfy { $0.hasPrefix("claude.") || $0.hasPrefix("codex.") })

        let snapshot = try XCTUnwrap(sink.events(named: "provider_accounts_daily").first)
        XCTAssertEqual(snapshot.keys.sorted(), ["install_id", "providers"])
        XCTAssertEqual(snapshot["install_id"] as? String, recorder.installID)
        let providers = try XCTUnwrap(snapshot["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.map { $0["provider_id"] as? String }, ["claude", "codex"])
        XCTAssertEqual(providers.map { $0["direct_count"] as? Int }, [2, 0])
        XCTAssertEqual(providers.map { $0["cliproxyapi_count"] as? Int }, [1, 1])
        XCTAssertTrue(providers.allSatisfy { $0.keys.sorted() == ["cliproxyapi_count", "direct_count", "provider_id"] })
    }
}
