import XCTest
@testable import OpenUsage

@MainActor
final class ICloudUsageSyncStoreTests: XCTestCase {
    func testEnableWritesLoadsAndDisableDeletesThisMac() async throws {
        let defaults = makeDefaults("enable-disable")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 && sync.displayedDocuments.count == 1 }

        XCTAssertEqual(sync.displayedDocuments.first?.deviceID, sync.deviceID)
        XCTAssertNil(sync.serviceError)

        sync.enabled = false
        try await waitUntil { await fileStore.deletedDeviceIDs.contains(sync.deviceID) }
        XCTAssertTrue(sync.documents.isEmpty)
    }

    func testAdjacentHistoryChangesDebounceToOneWrite() async throws {
        let defaults = makeDefaults("debounce")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(20),
            observesMetadataChanges: false
        )
        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 }

        sync.scheduleWrite()
        sync.scheduleWrite()
        sync.scheduleWrite()
        try await waitUntil { await fileStore.writeCount == 2 }
        try await Task.sleep(for: .milliseconds(40))

        let writeCount = await fileStore.writeCount
        XCTAssertEqual(writeCount, 2)
    }

    func testDisableDeletesWriteThatWasAlreadyInFlight() async throws {
        let defaults = makeDefaults("disable-in-flight-write")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        // Hold the enable write open so disable can race it deliberately, instead of hoping an
        // 80ms sleep is still in flight when the test flips the toggle on a loaded CI runner.
        await fileStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }

        sync.enabled = false
        try await waitUntil {
            await fileStore.deletedDeviceIDs.contains(sync.deviceID)
        }

        await fileStore.releaseWrite()
        try await waitUntil {
            let deletedCount = await fileStore.deletedDeviceIDs.filter { $0 == sync.deviceID }.count
            let writeInFlight = await fileStore.writeInFlight
            return deletedCount >= 2 && !writeInFlight && !sync.isSyncing
        }

        let documents = await fileStore.documents
        XCTAssertFalse(documents.contains { $0.deviceID == sync.deviceID })
    }

    func testUnavailableStoreSurfacesFriendlyError() async throws {
        let defaults = makeDefaults("unavailable")
        let fileStore = RecordingHistoryFileStore(unavailable: true)
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { sync.serviceError != nil && !sync.isSyncing }

        XCTAssertEqual(sync.serviceError, ICloudUsageSyncError.unavailable.localizedDescription)
        XCTAssertFalse(sync.isSyncing)
    }

    func testMalformedPeerMessageIsVisibleAndValidDocumentsStillLoad() async throws {
        let defaults = makeDefaults("malformed")
        let peer = UsageHistoryDocument(
            deviceID: "peer",
            deviceName: "Peer Mac",
            updatedAt: .now,
            providers: [:]
        )
        let fileStore = RecordingHistoryFileStore(
            seedDocuments: [peer],
            invalidFileMessages: ["broken.json: invalid value"]
        )
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { sync.invalidFileMessages.count == 1 }

        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })
        XCTAssertNotNil(sync.serviceError)
    }

    func testBackgroundReloadShowsSyncActivity() async throws {
        let defaults = makeDefaults("background-sync-activity")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil {
            await fileStore.writeCount == 1 && !sync.isSyncing
        }

        // Gate only the post-write reload so isSyncing stays true long enough to observe.
        await fileStore.holdNextLoad()
        sync.scheduleWrite()
        try await waitUntil {
            let writeCount = await fileStore.writeCount
            let loadInFlight = await fileStore.loadInFlight
            return writeCount == 2 && loadInFlight && sync.isSyncing
        }

        await fileStore.releaseLoad()
        try await waitUntil { !sync.isSyncing }
    }

    func testDeviceIdentitySurvivesPreferencesResetThroughKeychainStore() {
        let expectedID = UUID().uuidString.lowercased()
        let firstDefaults = makeDefaults("identity-first")
        firstDefaults.set(expectedID, forKey: "openusage.icloudSync.deviceID.v1")
        let deviceIDStore = MemoryDeviceIDStore()

        let first = ICloudUsageSyncStore(
            dataStore: makeDataStore(firstDefaults),
            defaults: firstDefaults,
            fileStore: RecordingHistoryFileStore(),
            deviceIDStore: deviceIDStore,
            observesMetadataChanges: false
        )
        let resetDefaults = makeDefaults("identity-after-reset")
        let afterReset = ICloudUsageSyncStore(
            dataStore: makeDataStore(resetDefaults),
            defaults: resetDefaults,
            fileStore: RecordingHistoryFileStore(),
            deviceIDStore: deviceIDStore,
            observesMetadataChanges: false
        )

        XCTAssertEqual(first.deviceID, expectedID)
        XCTAssertEqual(afterReset.deviceID, expectedID)
        XCTAssertEqual(resetDefaults.string(forKey: "openusage.icloudSync.deviceID.v1"), expectedID)
    }

    func testKeychainIdentityIsScopedToDevelopmentAndProductionBundles() throws {
        let keychain = ServiceKeychain()
        let development = KeychainICloudDeviceIDStore(
            keychain: keychain,
            bundleIdentifier: "com.robinebers.openusage.dev"
        )
        let production = KeychainICloudDeviceIDStore(
            keychain: keychain,
            bundleIdentifier: "com.robinebers.openusage"
        )

        try development.writeDeviceID("development-id")
        try production.writeDeviceID("production-id")

        XCTAssertEqual(try development.readDeviceID(), "development-id")
        XCTAssertEqual(try production.readDeviceID(), "production-id")
    }

    private func makeDataStore(_ defaults: UserDefaults) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageTests.ICloudSync.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private final class MemoryDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private var deviceID: String?

    func readDeviceID() throws -> String? {
        deviceID
    }

    func writeDeviceID(_ deviceID: String) throws {
        self.deviceID = deviceID
    }
}

private actor RecordingHistoryFileStore: UsageHistoryFileStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var invalidFileMessages: [String]
    private(set) var writeCount = 0
    private(set) var deletedDeviceIDs: [String] = []
    private let unavailable: Bool
    private(set) var loadInFlight = false
    private(set) var writeInFlight = false
    private var shouldHoldNextLoad = false
    private var shouldHoldNextWrite = false
    private var loadGate: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?

    init(
        unavailable: Bool = false,
        seedDocuments: [UsageHistoryDocument] = [],
        invalidFileMessages: [String] = []
    ) {
        self.unavailable = unavailable
        self.documents = seedDocuments
        self.invalidFileMessages = invalidFileMessages
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        loadInFlight = true
        defer { loadInFlight = false }
        if shouldHoldNextLoad {
            shouldHoldNextLoad = false
            await withCheckedContinuation { continuation in
                loadGate = continuation
            }
        }
        return UsageHistoryLoadResult(documents: documents, invalidFileMessages: invalidFileMessages)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        writeCount += 1
        writeInFlight = true
        defer { writeInFlight = false }
        if shouldHoldNextWrite {
            shouldHoldNextWrite = false
            await withCheckedContinuation { continuation in
                writeGate = continuation
            }
        }
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func delete(deviceID: String) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        deletedDeviceIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }

    func holdNextLoad() {
        shouldHoldNextLoad = true
    }

    func holdNextWrite() {
        shouldHoldNextWrite = true
    }

    func releaseLoad() {
        loadGate?.resume()
        loadGate = nil
    }

    func releaseWrite() {
        writeGate?.resume()
        writeGate = nil
    }
}
