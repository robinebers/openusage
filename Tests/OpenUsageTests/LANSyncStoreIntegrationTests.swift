import Foundation
import XCTest
@testable import OpenUsage

/// Real Bonjour + TCP integration. Opt-in because hosted CI environments often block multicast DNS.
/// Run locally with `OPENUSAGE_RUN_LAN_INTEGRATION=1 swift test --filter LANSyncStoreIntegrationTests`.
@MainActor
final class LANSyncStoreIntegrationTests: XCTestCase {
    func testTwoStoresDiscoverPairAndExchangeEncryptedSnapshots() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENUSAGE_RUN_LAN_INTEGRATION"] == "1",
            "Set OPENUSAGE_RUN_LAN_INTEGRATION=1 to exercise local Bonjour networking."
        )
        let defaultsA = makeDefaults("A")
        let defaultsB = makeDefaults("B")
        defer {
            defaultsA.removePersistentDomain(forName: defaultsASuite)
            defaultsB.removePersistentDomain(forName: defaultsBSuite)
        }
        var receivedByA: [String: ProviderSnapshot] = [:]
        var receivedByB: [String: ProviderSnapshot] = [:]
        let snapshotA = snapshot(device: "A", tokens: 100)
        let snapshotB = snapshot(device: "B", tokens: 250)
        let storeA = LANSyncStore(
            defaults: defaultsA,
            secretStore: MemoryLANSecretStore(),
            localSnapshots: { ["test": snapshotA] },
            applyRemoteSnapshots: { _, snapshots in receivedByA = snapshots },
            removeRemoteSnapshots: { _ in receivedByA = [:] }
        )
        let storeB = LANSyncStore(
            defaults: defaultsB,
            secretStore: MemoryLANSecretStore(),
            localSnapshots: { ["test": snapshotB] },
            applyRemoteSnapshots: { _, snapshots in receivedByB = snapshots },
            removeRemoteSnapshots: { _ in receivedByB = [:] }
        )
        defer {
            storeA.enabled = false
            storeB.enabled = false
        }

        storeA.enabled = true
        storeB.enabled = true
        try await waitUntil("Bonjour listeners to register") {
            storeA.testingListenerEndpoint != nil && storeB.testingListenerEndpoint != nil
        }
        guard let endpointA = storeA.testingListenerEndpoint,
              let endpointB = storeB.testingListenerEndpoint else {
            return XCTFail("expected listener endpoints")
        }

        // Hosted test runners can deny multicast browsing even though both Bonjour listeners register.
        // Connect through their real listener ports so the full pairing/auth/encryption transport still
        // runs over Network.framework rather than falling back to a mock channel.
        storeA.pairForTesting(deviceID: storeB.deviceID, name: storeB.deviceName, endpoint: endpointB)
        try await waitUntil("pairing code") {
            if case .compareCode = storeA.outgoingPairing { return !storeB.incomingPairRequests.isEmpty }
            return false
        }
        guard case .compareCode(_, _, let codeA) = storeA.outgoingPairing,
              let request = storeB.incomingPairRequests.first else {
            return XCTFail("expected code on both peers")
        }
        XCTAssertEqual(codeA, request.code)
        storeB.approvePairing(request.id)

        try await waitUntil("pairing and first encrypted sync") {
            storeA.pairedDevices.contains(where: { $0.id == storeB.deviceID })
                && storeB.pairedDevices.contains(where: { $0.id == storeA.deviceID })
                && receivedByA["test"] != nil
        }
        XCTAssertEqual(tokenCount(in: receivedByA["test"]), 250)

        await storeB.syncForTesting(
            device: LANPairedDevice(id: storeA.deviceID, name: storeA.deviceName),
            endpoint: endpointA
        )
        try await waitUntil("reverse encrypted sync") { receivedByB["test"] != nil }
        XCTAssertEqual(tokenCount(in: receivedByB["test"]), 100)
    }

    private let defaultsASuite = "OpenUsageTests.LANSync.Integration.A"
    private let defaultsBSuite = "OpenUsageTests.LANSync.Integration.B"

    private func makeDefaults(_ suffix: String) -> UserDefaults {
        let name = suffix == "A" ? defaultsASuite : defaultsBSuite
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func snapshot(device: String, tokens: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.values(label: "Today", values: [
                MetricValue(number: tokens, kind: .count, label: "tokens")
            ])],
            warning: device
        )
    }

    private func tokenCount(in snapshot: ProviderSnapshot?) -> Double? {
        guard let line = snapshot?.line(label: "Today"),
              case .values(_, let values, _, _, _, _) = line else { return nil }
        return values.first(where: { $0.kind == .count })?.number
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(15),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)")
                throw IntegrationError.timeout(description)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum IntegrationError: Error { case timeout(String) }
}

private final class MemoryLANSecretStore: LANSyncSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func secret(for deviceID: String) throws -> Data? {
        lock.withLock { values[deviceID] }
    }

    func store(_ secret: Data, for deviceID: String) throws {
        lock.withLock { values[deviceID] = secret }
    }

    func deleteSecret(for deviceID: String) throws {
        lock.withLock { values[deviceID] = nil }
    }
}
