import Foundation
import XCTest
import OpenUsageWidgetSupport
@testable import OpenUsage

final class WidgetBridgeFileStoreTests: XCTestCase {
    func testRoundTripAndSemanticContentIgnoresGenerationDate() throws {
        let url = temporaryURL()
        let store = WidgetBridgeFileStore(fileURL: url)
        let first = document(generatedAt: Date(timeIntervalSince1970: 100))
        let later = document(generatedAt: Date(timeIntervalSince1970: 200))

        try store.write(first)

        XCTAssertEqual(try store.read(), first)
        XCTAssertEqual(first.semanticContent, later.semanticContent)
    }

    func testUnsupportedWriteLeavesPreviousGoodFileUntouched() throws {
        let url = temporaryURL()
        let store = WidgetBridgeFileStore(fileURL: url)
        let valid = document(generatedAt: Date(timeIntervalSince1970: 100))
        try store.write(valid)

        let invalid = WidgetBridgeDocument(schemaVersion: 99, generatedAt: Date(), providers: [])
        XCTAssertThrowsError(try store.write(invalid)) { error in
            XCTAssertEqual(error as? WidgetBridgeFileError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try store.read(), valid)
    }

    func testMissingAndCorruptFilesFailExplicitly() throws {
        let url = temporaryURL()
        let store = WidgetBridgeFileStore(fileURL: url)
        XCTAssertNil(try store.read())

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: url)
        XCTAssertThrowsError(try store.read())
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageWidgetBridgeTests-\(UUID().uuidString)")
            .appendingPathComponent(WidgetBridgeFileStore.fileName)
    }

    private func document(generatedAt: Date) -> WidgetBridgeDocument {
        WidgetBridgeDocument(
            generatedAt: generatedAt,
            providers: [WidgetProviderRecord(
                id: "claude",
                displayName: "Claude",
                isEnabled: true,
                plan: "Pro",
                refreshedAt: Date(timeIntervalSince1970: 50),
                health: .ready,
                primaryMetrics: [],
                secondaryMetrics: []
            )]
        )
    }
}

@MainActor
final class WidgetBridgeExporterTests: XCTestCase {
    func testExportsPresentationRowsInLayoutOrderAndOmitsCharts() {
        let fixture = Fixture()
        fixture.dataStore.snapshots[fixture.provider.id] = fixture.snapshot

        let document = fixture.exporter.makeDocument(generatedAt: fixture.now)

        XCTAssertEqual(document.providers.map(\.id), [fixture.provider.id])
        let provider = try! XCTUnwrap(document.providers.first)
        XCTAssertTrue(provider.isEnabled)
        XCTAssertEqual(provider.health, .ready)
        XCTAssertEqual(provider.plan, "Pro")
        XCTAssertEqual(provider.primaryMetrics.map(\.id), ["test.session"])
        XCTAssertEqual(provider.secondaryMetrics.map(\.id), ["test.balance"])
        XCTAssertEqual(provider.primaryMetrics.first?.headline, "60% left")
        XCTAssertEqual(provider.primaryMetrics.first?.progressFraction, 0.6)
        XCTAssertEqual(provider.primaryMetrics.first?.resetAt, fixture.now.addingTimeInterval(3_600))
        XCTAssertNil(provider.primaryMetrics.first?.detail)
        XCTAssertFalse(provider.primaryMetrics.contains { $0.id == "test.trend" })
    }

    func testExportsFailureWithoutRawErrorAndRetainsLastGoodRows() throws {
        let fixture = Fixture()
        fixture.dataStore.snapshots[fixture.provider.id] = fixture.snapshot
        fixture.dataStore.providerErrors[fixture.provider.id] = "secret token expired"

        let document = fixture.exporter.makeDocument(generatedAt: fixture.now)
        let provider = try XCTUnwrap(document.providers.first)
        XCTAssertEqual(provider.health, .failed)
        XCTAssertEqual(provider.primaryMetrics.first?.headline, "60% left")

        let encoded = try JSONEncoder().encode(document)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret token expired"))
    }

    func testExportsDisabledProviderInsteadOfDroppingIt() throws {
        let fixture = Fixture(enabled: false)
        let provider = try XCTUnwrap(fixture.exporter.makeDocument().providers.first)
        XCTAssertFalse(provider.isEnabled)
        XCTAssertEqual(provider.health, .noData)
    }
}

@MainActor
final class WidgetBridgeCoordinatorTests: XCTestCase {
    func testWritesAndReloadsOnlyForSemanticChanges() async {
        let fixture = Fixture()
        fixture.dataStore.snapshots[fixture.provider.id] = fixture.snapshot
        let store = MemoryBridgeStore()
        var reloadCount = 0
        let coordinator = WidgetBridgeCoordinator(
            exporter: fixture.exporter,
            store: store,
            debounceDuration: .zero,
            now: { fixture.now },
            reload: { reloadCount += 1 }
        )

        coordinator.start()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(reloadCount, 1)

        coordinator.exportIfChanged()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(reloadCount, 1)

        fixture.dataStore.meterStyle = .used
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(reloadCount, 2)
        XCTAssertEqual(store.documents.last?.providers.first?.primaryMetrics.first?.headline, "40% used")
    }
}

@MainActor
private final class MemoryBridgeStore: WidgetBridgePersisting {
    var documents: [WidgetBridgeDocument] = []

    func read() throws -> WidgetBridgeDocument? { documents.last }
    func write(_ document: WidgetBridgeDocument) throws { documents.append(document) }
}

@MainActor
private final class Fixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
    let registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let enablement: ProviderEnablementStore
    let snapshot: ProviderSnapshot

    var exporter: WidgetBridgeExporter {
        WidgetBridgeExporter(registry: registry, layout: layout, dataStore: dataStore, enablement: enablement)
    }

    init(enabled: Bool = true) {
        let session = WidgetDescriptor(
            id: "test.session", providerID: provider.id, metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let balance = WidgetDescriptor(
            id: "test.balance", providerID: provider.id, metricLabel: "Balance",
            sample: WidgetData(title: "Balance", icon: provider.icon, kind: .dollars, used: 0)
        )
        var chartSample = WidgetData(title: "Trend", icon: provider.icon, kind: .count, used: 0)
        chartSample.isChart = true
        let chart = WidgetDescriptor(
            id: "test.trend", providerID: provider.id, metricLabel: "Trend", sample: chartSample
        )
        let descriptors = [session, balance, chart]
        registry = WidgetRegistry(providers: [provider], descriptors: descriptors)

        let defaults = UserDefaults(suiteName: "WidgetBridgeTests-\(UUID().uuidString)")!
        enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(enabled ? [provider.id] : [])
        layout = LayoutStore(
            registry: registry,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: descriptors.map(\.id),
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: [balance.id],
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [
                .progress(
                    label: "Session", used: 40, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval(3_600)
                ),
                .values(label: "Balance", values: [.init(number: 12, kind: .dollars)]),
                .chart(label: "Trend", points: [.init(value: 1, label: "Today")])
            ],
            refreshedAt: now
        )
        let runtime = TestProviderRuntime(provider: provider, descriptors: descriptors, snapshot: snapshot)
        dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(
                userDefaults: defaults,
                storageKey: "snapshots",
                ttl: 600,
                now: { Date() }
            ),
            defaults: defaults,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
    }
}
