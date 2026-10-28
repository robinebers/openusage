import Foundation
import XCTest
import OpenUsageWidgetSupport
@testable import OpenUsage

final class WidgetBridgeFileStoreTests: XCTestCase {
    func testRoundTripAndSemanticContentIgnoresGenerationDate() throws {
        let store = WidgetBridgeFileStore(fileURL: temporaryURL())
        let first = document(generatedAt: Date(timeIntervalSince1970: 100))
        let later = document(generatedAt: Date(timeIntervalSince1970: 200))

        try store.write(first)

        XCTAssertEqual(try store.read(), first)
        XCTAssertEqual(first.semanticContent, later.semanticContent)
    }

    func testUnsupportedWriteLeavesPreviousGoodFileUntouched() throws {
        let store = WidgetBridgeFileStore(fileURL: temporaryURL())
        let valid = document(generatedAt: Date(timeIntervalSince1970: 100))
        try store.write(valid)

        let invalid = WidgetBridgeDocument(schemaVersion: 99, generatedAt: Date(), providers: [])
        XCTAssertThrowsError(try store.write(invalid)) { error in
            XCTAssertEqual(error as? WidgetBridgeFileError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try store.read(), valid)
    }

    func testMissingCorruptAndUnsupportedFilesFailExplicitly() throws {
        let url = temporaryURL()
        let store = WidgetBridgeFileStore(fileURL: url)
        XCTAssertNil(try store.read())

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        XCTAssertThrowsError(try store.read())

        try Data(#"{"schemaVersion":99,"generatedAt":"2026-09-01T00:00:00Z","providers":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? WidgetBridgeFileError, .unsupportedSchema(99))
        }
    }

    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageWidgetBridgeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(WidgetBridgeFileStore.fileName)
    }

    private func document(generatedAt: Date) -> WidgetBridgeDocument {
        WidgetBridgeDocument(
            generatedAt: generatedAt,
            providers: [WidgetProviderRecord(
                id: "claude@00000001", displayName: "Claude · Work", iconID: "claude", plan: "Pro",
                refreshedAt: Date(timeIntervalSince1970: 50), health: .ready, metrics: []
            )]
        )
    }
}

@MainActor
final class WidgetBridgeExporterTests: XCTestCase {
    func testExportsShownMetricsInSavedOrderWithDisplayValuesAndResetDate() throws {
        let fixture = Fixture(defaults: isolatedDefaults())
        fixture.dataStore.snapshots[fixture.provider.id] = fixture.snapshot
        XCTAssertTrue(fixture.layout.reorderMetric(dragged: fixture.session.id, target: fixture.balance.id, in: fixture.provider.id))
        fixture.layout.setMetricEnabled(fixture.resets.id, false)

        let provider = try XCTUnwrap(fixture.exporter.makeDocument(generatedAt: fixture.now).providers.first)

        XCTAssertEqual(provider.id, fixture.provider.id)
        XCTAssertEqual(provider.displayName, "ChatGPT · Work")
        XCTAssertEqual(provider.iconID, "codex")
        XCTAssertEqual(provider.health, .ready)
        XCTAssertEqual(provider.plan, "Pro")
        XCTAssertEqual(provider.metrics.map(\.id), [fixture.balance.id, fixture.session.id])
        let session = try XCTUnwrap(provider.metrics.last)
        XCTAssertEqual(session.headline, "60% left")
        XCTAssertEqual(session.progressFraction, 0.6)
        XCTAssertEqual(session.resetAt, fixture.now.addingTimeInterval(3_600))
        XCTAssertNil(session.detail)
    }

    func testPreservesDistinctAccountsAndSavedAccountOrder() {
        let defaults = isolatedDefaults()
        let work = Provider(id: "claude@00000001", kind: .claude, accountLabel: "Work")
        let personal = Provider(id: "claude@00000002", kind: .claude, accountLabel: "Personal")
        let chatGPT = Provider(id: "codex@00000003", kind: .codex, accountLabel: "Work")
        let providers = [work, personal, chatGPT]
        let runtimes = providers.map { provider in
            StubRuntime(
                provider: provider,
                descriptors: [.percent(key: "session", provider: provider, title: "Session")],
                snapshot: ProviderSnapshot(provider: provider, plan: nil, lines: [])
            )
        }
        let registry = WidgetRegistry.from(runtimes)
        let layout = LayoutStore(registry: registry, defaults: defaults)
        layout.providerOrder = [personal.id, work.id, chatGPT.id]
        let dataStore = WidgetDataStore.forTesting(runtimes, defaults: defaults)
        let document = WidgetBridgeExporter(layout: layout, dataStore: dataStore).makeDocument()

        XCTAssertEqual(document.providers.map(\.id), [personal.id, work.id, chatGPT.id])
        XCTAssertEqual(document.providers.map(\.displayName), ["Claude · Personal", "Claude · Work", "ChatGPT · Work"])
        XCTAssertEqual(document.providers.map(\.iconID), ["claude", "claude", "codex"])
    }

    func testFailureRetainsLastGoodRowsAndDistinguishesProviderWaits() async throws {
        let failureKinds: [RefreshFailure.Kind] = [.refused, .rateLimited(retryAfter: 120)]
        for kind in failureKinds {
            let fixture = Fixture(defaults: isolatedDefaults())
            fixture.dataStore.snapshots[fixture.provider.id] = fixture.snapshot
            fixture.runtime.answer = { _ in .failure(RefreshFailure(message: "secret token expired", kind: kind)) }

            let outcome = await fixture.dataStore.refresh(providerID: fixture.provider.id, force: true)
            XCTAssertEqual(outcome, .failed)
            let document = fixture.exporter.makeDocument(generatedAt: fixture.now)
            let provider = try XCTUnwrap(document.providers.first)
            XCTAssertEqual(provider.health, kind == .rateLimited(retryAfter: 120) ? .ready : .failed)
            XCTAssertEqual(provider.metrics.first?.headline, "60% left")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(document), as: UTF8.self).contains("secret token expired"))
        }
    }

    func testUnrefreshedAccountAndAllHiddenMetricsRemainAvailableForRecovery() throws {
        let fixture = Fixture(defaults: isolatedDefaults())
        let before = try XCTUnwrap(fixture.exporter.makeDocument().providers.first)
        XCTAssertEqual(before.health, .noData)
        XCTAssertEqual(before.metrics.map(\.id), fixture.runtime.widgetDescriptors.map(\.id))
        XCTAssertTrue(before.metrics.allSatisfy { !$0.hasData })
        XCTAssertEqual(
            WidgetBridgeExporter.enabledMetricDescriptors(for: fixture.provider.id, layout: fixture.layout).map(\.id),
            fixture.runtime.widgetDescriptors.map(\.id)
        )

        for descriptor in fixture.runtime.widgetDescriptors { fixture.layout.setMetricEnabled(descriptor.id, false) }

        let hidden = try XCTUnwrap(fixture.exporter.makeDocument().providers.first)
        XCTAssertEqual(hidden.id, fixture.provider.id)
        XCTAssertTrue(hidden.metrics.isEmpty)
        XCTAssertEqual(hidden.health, .noData)
        XCTAssertTrue(WidgetBridgeExporter.enabledMetricDescriptors(for: fixture.provider.id, layout: fixture.layout).isEmpty)
    }

    func testFreshSessionOmitsResetAndZeroResetCreditsAreNotRendered() throws {
        let fixture = Fixture(defaults: isolatedDefaults())
        var snapshot = fixture.snapshot
        snapshot.lines = [
            .progress(label: "Session", used: 0, limit: 100, format: .percent, resetsAt: fixture.now.addingTimeInterval(3_600)),
            .values(label: "Resets", values: [.init(number: 0, kind: .count)])
        ]
        fixture.dataStore.snapshots[fixture.provider.id] = snapshot

        let provider = try XCTUnwrap(fixture.exporter.makeDocument(generatedAt: fixture.now).providers.first)
        let session = try XCTUnwrap(provider.metrics.first { $0.id == fixture.session.id })
        let resets = try XCTUnwrap(provider.metrics.first { $0.id == fixture.resets.id })
        XCTAssertTrue(session.hasData)
        XCTAssertNil(session.resetAt)
        XCTAssertFalse(resets.hasData)
    }
}

@MainActor
final class WidgetBridgeCoordinatorTests: XCTestCase {
    func testTimestampOnlyRefreshWritesWithoutReloadUntilFreshnessUpdateIsDue() {
        let fixture = Fixture(defaults: isolatedDefaults())
        var clock = fixture.now
        var snapshot = fixture.snapshot
        fixture.dataStore.snapshots[fixture.provider.id] = snapshot
        let store = MemoryBridgeStore()
        var reloadCount = 0
        let coordinator = WidgetBridgeCoordinator(
            exporter: fixture.exporter, store: store, debounceDuration: .seconds(60),
            now: { clock }, reload: { reloadCount += 1 }
        )
        coordinator.start()
        XCTAssertEqual(reloadCount, 1)

        clock = clock.addingTimeInterval(300)
        snapshot.refreshedAt = clock
        fixture.dataStore.snapshots[fixture.provider.id] = snapshot
        coordinator.exportIfChanged()
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.documents.last?.providers.first?.refreshedAt, clock)
        XCTAssertEqual(reloadCount, 1, "a timestamp-only refresh should persist without requesting a redraw")

        clock = clock.addingTimeInterval(600)
        snapshot.refreshedAt = clock
        fixture.dataStore.snapshots[fixture.provider.id] = snapshot
        coordinator.exportIfChanged()
        XCTAssertEqual(store.documents.count, 3)
        XCTAssertEqual(reloadCount, 2, "a healthy account should refresh the widget's freshness before it becomes stale")

        clock = clock.addingTimeInterval(900)
        coordinator.exportIfChanged()
        XCTAssertEqual(reloadCount, 2, "a clock tick with no new provider data needs no reload")

        fixture.dataStore.meterStyle = .used
        coordinator.exportIfChanged()
        XCTAssertEqual(reloadCount, 3, "a changed displayed value must not wait for the freshness interval")
    }

    func testWritesAndReloadsOnlyForSemanticChangesAndObservesDisplayChanges() async throws {
        let fixture = Fixture(defaults: isolatedDefaults())
        fixture.dataStore.snapshots[fixture.provider.id] = fixture.snapshot
        let store = MemoryBridgeStore()
        var reloadCount = 0
        let coordinator = WidgetBridgeCoordinator(
            exporter: fixture.exporter, store: store, debounceDuration: .zero,
            now: { fixture.now }, reload: { reloadCount += 1 }
        )

        coordinator.start()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(reloadCount, 1)
        coordinator.exportIfChanged()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(reloadCount, 1)

        fixture.dataStore.meterStyle = .used
        try await waitUntil { store.documents.last?.providers.first?.metrics.first?.headline == "40% used" }
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(reloadCount, 2)
    }

    func testObservesAccountAddRenameAndRemovalThroughTheCurrentContainer() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: Data()))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let store = MemoryBridgeStore()
        let coordinator = WidgetBridgeCoordinator(
            exporter: WidgetBridgeExporter(layout: container.layout, dataStore: container.dataStore),
            store: store, debounceDuration: .zero, reload: {}
        )
        coordinator.start()
        XCTAssertEqual(store.documents.last?.providers, [])

        let work = accounts.add(kind: .codex, label: "Work", credential: .apiKey("test-only"))
        try await waitUntil { store.documents.last?.providers.map(\.id) == [work.cardID] }
        XCTAssertEqual(store.documents.last?.providers.first?.displayName, "ChatGPT · Work")
        let personal = accounts.add(kind: .codex, label: "Personal", credential: .apiKey("test-only"))
        try await waitUntil { store.documents.last?.providers.map(\.id) == [work.cardID, personal.cardID] }

        accounts.rename(work.id, to: "Office")
        try await waitUntil { store.documents.last?.providers.first?.displayName == "ChatGPT · Office" }
        accounts.remove(work.id)
        try await waitUntil { store.documents.last?.providers.map(\.id) == [personal.cardID] }
        XCTAssertNil(container.dataStore.snapshots[work.cardID])

        accounts.remove(personal.id)
        try await waitUntil { store.documents.last?.providers.isEmpty == true }
        XCTAssertTrue(container.layout.orderedProviders().isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), file: file, line: line)
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
    let provider = Provider(id: "codex@00000001", kind: .codex, accountLabel: "Work")
    let session: WidgetDescriptor
    let balance: WidgetDescriptor
    let resets: WidgetDescriptor
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let snapshot: ProviderSnapshot
    let runtime: StubRuntime

    var exporter: WidgetBridgeExporter { WidgetBridgeExporter(layout: layout, dataStore: dataStore) }

    init(defaults: UserDefaults) {
        session = .percent(key: "session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
        balance = .dollarBalance(key: "balance", provider: provider, title: "Balance", valueWord: "available")
        resets = .values(key: "resets", provider: provider, title: "Resets", showsResetExpiries: true)
        let descriptors = [session, balance, resets]
        snapshot = ProviderSnapshot(
            provider: provider, plan: "Pro",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent, resetsAt: now.addingTimeInterval(3_600)),
                .values(label: "Balance", values: [.init(number: 12, kind: .dollars)]),
                .values(label: "Resets", values: [.init(number: 2, kind: .count)], expiriesAt: [now.addingTimeInterval(86_400)])
            ],
            refreshedAt: now
        )
        runtime = StubRuntime(provider: provider, descriptors: descriptors, snapshot: snapshot)
        layout = LayoutStore(registry: .from([runtime]), defaults: defaults)
        dataStore = WidgetDataStore.forTesting([runtime], defaults: defaults, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
}
