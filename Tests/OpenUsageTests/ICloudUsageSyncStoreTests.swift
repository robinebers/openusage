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
        let fileStore = RecordingHistoryFileStore(writeDelay: .milliseconds(80))
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }

        sync.enabled = false
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
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { sync.invalidFileMessages.count == 1 }

        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })
        XCTAssertNotNil(sync.serviceError)
    }

    func testBackgroundReloadShowsSyncActivity() async throws {
        let defaults = makeDefaults("background-sync-activity")
        let fileStore = RecordingHistoryFileStore(loadDelay: .milliseconds(80))
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil {
            await fileStore.writeCount == 1 && !sync.isSyncing
        }

        sync.scheduleWrite()
        try await waitUntil {
            let writeCount = await fileStore.writeCount
            let loadInFlight = await fileStore.loadInFlight
            return writeCount == 2 && loadInFlight
        }

        XCTAssertTrue(sync.isSyncing)
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
        timeout: Duration = .seconds(1),
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

private actor RecordingHistoryFileStore: UsageHistoryFileStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var invalidFileMessages: [String]
    private(set) var writeCount = 0
    private(set) var deletedDeviceIDs: [String] = []
    private let unavailable: Bool
    private let loadDelay: Duration?
    private let writeDelay: Duration?
    private(set) var loadInFlight = false
    private(set) var writeInFlight = false

    init(
        unavailable: Bool = false,
        seedDocuments: [UsageHistoryDocument] = [],
        invalidFileMessages: [String] = [],
        loadDelay: Duration? = nil,
        writeDelay: Duration? = nil
    ) {
        self.unavailable = unavailable
        self.documents = seedDocuments
        self.invalidFileMessages = invalidFileMessages
        self.loadDelay = loadDelay
        self.writeDelay = writeDelay
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        loadInFlight = true
        defer { loadInFlight = false }
        if let loadDelay {
            try await Task.sleep(for: loadDelay)
        }
        return UsageHistoryLoadResult(documents: documents, invalidFileMessages: invalidFileMessages)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        writeCount += 1
        writeInFlight = true
        defer { writeInFlight = false }
        if let writeDelay {
            try await Task.sleep(for: writeDelay)
        }
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func delete(deviceID: String) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        deletedDeviceIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }
}
