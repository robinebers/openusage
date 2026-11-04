#if OPENUSAGE_DEVELOPMENT
import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class DevelopmentDemoTests: XCTestCase {
    func testSampleLaunchRequiresTheDemoIdentityAndExplicitArgument() throws {
        XCTAssertTrue(try DemoSession.requested(
            bundleIdentifier: DevelopmentDataMode.demoBundleID,
            arguments: ["OpenUsage", DevelopmentDataMode.demoArgument]
        ))
        XCTAssertFalse(try DemoSession.requested(
            bundleIdentifier: DevelopmentDataMode.normalBundleID, arguments: ["OpenUsage"]
        ))
        XCTAssertFalse(try DemoSession.requested(bundleIdentifier: "com.robinebers.openusage", arguments: ["OpenUsage"]))
        for identity in [DevelopmentDataMode.normalBundleID, "com.robinebers.openusage", "unknown", nil] {
            XCTAssertThrowsError(try DemoSession.requested(
                bundleIdentifier: identity, arguments: ["OpenUsage", DevelopmentDataMode.demoArgument]
            ))
        }
        XCTAssertThrowsError(try DemoSession.requested(
            bundleIdentifier: DevelopmentDataMode.demoBundleID, arguments: ["OpenUsage"]
        ))
    }

    func testEveryProviderHasSampleUsageAndKeepsTheExistingMetricDeclarationOrder() throws {
        let now = Date()
        let fixtures = DemoFixtures.accounts(at: now)
        let laterFixtures = DemoFixtures.accounts(at: now.addingTimeInterval(86_400))
        XCTAssertEqual(Set(fixtures.map(\.kind)), Set(ProviderKind.allCases))
        XCTAssertEqual(Set(fixtures.map(\.cardID)).count, fixtures.count)
        XCTAssertEqual(fixtures.map(\.id), laterFixtures.map(\.id), "a restart must keep stable sample identities")
        XCTAssertEqual(fixtures.map(\.label), laterFixtures.map(\.label))
        XCTAssertTrue(fixtures.contains { $0.label.contains("@example.com") })
        XCTAssertTrue(fixtures.contains { !$0.label.contains("@") })
        XCTAssertTrue(fixtures.contains { $0.organization != nil })
        XCTAssertTrue(fixtures.contains { $0.hub != nil })

        let runtimes = DemoProviderRuntime.make(accounts: fixtures, existing: [])
        XCTAssertEqual(runtimes.count, fixtures.count)
        for (account, runtime) in zip(fixtures, runtimes) {
            XCTAssertEqual(runtime.provider.id, account.cardID)
            XCTAssertEqual(runtime.widgetDescriptors.map(\.id), AccountProviderRuntime.widgetDescriptors(for: account).map(\.id),
                           "the sample must not invent or reorder metrics")
        }

        let container = try makeContainer(now: now)
        XCTAssertTrue(container.isSampleData)
        XCTAssertTrue(container.accounts.credentialVault is DemoCredentialVault)
        XCTAssertTrue(container.accounts.hubKeys is DemoHubKeyVault)
        XCTAssertEqual(Set(container.layout.orderedProviderIDs()), Set(fixtures.map(\.cardID)))
        let accounts = container.dataStore.accounts(in: container.layout.displayGroups)
        XCTAssertEqual(Set(accounts.map { $0.provider.kind }), Set(ProviderKind.allCases))
        XCTAssertTrue(accounts.allSatisfy { !$0.lines.isEmpty && $0.lines.contains(where: \.data.hasData) })
        XCTAssertTrue(fixtures.contains { container.dataStore.plan(for: $0.cardID) != nil })

        let readings = accounts.flatMap(\.lines).map(\.data)
        XCTAssertTrue(readings.contains { $0.isBounded && $0.severity == .normal })
        XCTAssertTrue(readings.contains { $0.severity == .warning })
        XCTAssertTrue(readings.contains { $0.severity == .critical })
        XCTAssertTrue(readings.contains { $0.meterState(now: now) == .spent })
        let board = container.dataStore.priorityBoard(
            in: container.layout.displayGroups, pinned: container.layout.state.priorityPinIDs, now: now
        )
        XCTAssertFalse(board.attention.isEmpty)
        XCTAssertFalse(board.usedUp.isEmpty)
        XCTAssertFalse(board.notices.isEmpty)
        XCTAssertTrue(board.waiting.isEmpty, "sample accounts must show immediately without a provider sign-in")
    }

    func testManualAndHourlyRefreshKeepServingLocalFixtures() async throws {
        let container = try makeContainer()
        let ids = container.accounts.accounts.map(\.cardID)
        let plans = Dictionary(uniqueKeysWithValues: ids.map { ($0, container.dataStore.plan(for: $0)) })
        let amounts = amounts(in: container)

        let outcomes = await container.dataStore.refresh(providerIDs: ids, force: true)
        XCTAssertEqual(outcomes.count, ids.count)
        XCTAssertTrue(outcomes.allSatisfy { if case .refreshed = $0 { true } else { false } },
                      "a refresh must not fall through to sign-in or provider APIs")
        await container.dataStore.refreshHourlyReads()

        XCTAssertEqual(Set(container.dataStore.snapshots.keys), Set(ids))
        XCTAssertEqual(self.amounts(in: container), amounts)
        for id in ids {
            XCTAssertEqual(container.dataStore.plan(for: id), plans[id] ?? nil)
            XCTAssertNil(container.dataStore.errorMessage(for: id), "the rejecting HTTP client must never be needed")
        }
        XCTAssertTrue(container.dataStore.backoffs.isEmpty)
    }

    func testSampleRuntimeReconciliationReusesInstancesAndUpdatesNames() async throws {
        let now = Date()
        let accounts = DemoFixtures.accounts(at: now)
        let initial: [ProviderRuntime] = accounts.map { DemoProviderRuntime(account: $0, now: { now }) }
        let index = try XCTUnwrap(accounts.firstIndex { $0.label == "Work Account" })
        let before = try await initial[index].refresh().get()
        var renamed = accounts
        renamed[index].label = "Renamed Sample"
        let reconciled = DemoProviderRuntime.make(accounts: renamed, existing: initial)
        XCTAssertTrue(reconciled[index] === initial[index])
        XCTAssertEqual(reconciled[index].provider.accountName, "Renamed Sample")
        let after = try await reconciled[index].refresh().get()
        XCTAssertEqual(after.lines, before.lines, "renaming a sample must not change its fixture scenario")
        XCTAssertEqual(after.plan, before.plan)

        let removed = DemoProviderRuntime.make(accounts: Array(renamed.dropFirst()), existing: reconciled)
        XCTAssertEqual(removed.map(\.provider.id), Array(renamed.dropFirst()).map(\.cardID))
        XCTAssertTrue(removed[0] === reconciled[1])
    }

    func testRenameReorderAndRemovalStayInsideTheSampleContainer() async throws {
        let container = try makeContainer()
        let saved = try XCTUnwrap(container.accounts.accounts.first)
        let store = container.dataStore
        let layout = container.layout
        let before = amounts(in: container)

        container.accounts.rename(saved.id, to: "Sample Rename")
        XCTAssertTrue(container.dataStore === store)
        XCTAssertTrue(container.layout === layout)
        XCTAssertEqual(layout.provider(id: saved.cardID)?.accountName, "Sample Rename")
        let renamed = await store.refresh(providerID: saved.cardID, force: true)
        if case .refreshed = renamed {} else { XCTFail("the renamed account lost its sample runtime") }
        XCTAssertEqual(amounts(in: container), before)

        let metrics = layout.metricOrder(for: saved.cardID)
        if metrics.count > 1 {
            XCTAssertTrue(layout.reorderMetric(dragged: metrics[0], target: metrics[1], in: saved.cardID))
            XCTAssertNotEqual(layout.metricOrder(for: saved.cardID), metrics)
        }
        container.accounts.remove(saved.id)
        XCTAssertFalse(container.accounts.accounts.contains { $0.id == saved.id })
        XCTAssertNil(layout.provider(id: saved.cardID))
        XCTAssertNil(store.snapshots[saved.cardID])
        let refreshed = await store.refresh(providerIDs: container.accounts.accounts.map(\.cardID), force: true)
        XCTAssertTrue(refreshed.allSatisfy { if case .refreshed = $0 { true } else { false } })
    }

    func testRestartResetsOnlyTheDedicatedDemoDomainAndRestoresTheSamples() throws {
        let defaults = makeDefaults()
        let unrelated = isolatedDefaults()
        unrelated.set("keep-real-state", forKey: "sentinel")
        let now = Date()
        let first = try DemoSession.makeContainer(defaults: defaults, resetDomain: DevelopmentDataMode.demoBundleID, now: now)
        let original = first.accounts.accounts
        let account = try XCTUnwrap(original.first)
        first.accounts.rename(account.id, to: "Temporary Name")
        first.accounts.remove(account.id)
        defaults.set("temporary-setting", forKey: "demo-edit")

        let restarted = try DemoSession.makeContainer(
            defaults: defaults, resetDomain: DevelopmentDataMode.demoBundleID, now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(restarted.accounts.accounts.map(\.id), original.map(\.id))
        XCTAssertEqual(restarted.accounts.accounts.map(\.label), original.map(\.label))
        XCTAssertNil(defaults.string(forKey: "demo-edit"))
        XCTAssertEqual(unrelated.string(forKey: "sentinel"), "keep-real-state")
        XCTAssertFalse(defaults.requestedResets.isEmpty)
        XCTAssertTrue(defaults.requestedResets.allSatisfy { $0 == DevelopmentDataMode.demoBundleID },
                      "the session must never reset development or production preferences")
    }

    func testResetRejectsAnyNonDemoDomainBeforeChangingDefaults() {
        let defaults = makeDefaults()
        defaults.set("preserved", forKey: "sentinel")
        for domain in [DevelopmentDataMode.normalBundleID, "com.robinebers.openusage", "arbitrary-test-domain"] {
            XCTAssertThrowsError(try DemoSession.makeContainer(defaults: defaults, resetDomain: domain))
        }
        XCTAssertTrue(defaults.requestedResets.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "sentinel"), "preserved")
    }

    func testCredentialReplacementAndRealResetClaimsAreUnavailableForSamples() async throws {
        let container = try makeContainer()
        let account = try XCTUnwrap(container.accounts.accounts.first)
        let before = container.accounts.accounts
        XCTAssertNil(container.resetClaim(for: account.cardID))
        do {
            try await container.replaceCredential(.apiKey("must-not-be-saved"), for: account.cardID)
            XCTFail("sample mode must reject real credential replacement")
        } catch {}
        let hub = try XCTUnwrap(container.accounts.hubs.first)
        do {
            try await container.replaceHubKey("must-not-be-saved", for: hub.id)
            XCTFail("sample mode must reject hub-key replacement")
        } catch {}
        XCTAssertEqual(container.accounts.accounts, before)
        XCTAssertNil(try container.accounts.credential(for: account.id))
        XCTAssertNil(try container.accounts.hubKeys.load(hub.id))
    }

    func testTheDemoHTTPClientRejectsRequestsInsteadOfSendingThem() async throws {
        do {
            _ = try await DemoHTTPClient().send(HTTPRequest(method: "GET", url: URL(string: "https://example.com/must-not-send")!))
            XCTFail("the sample HTTP boundary must reject every request")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    private func makeContainer(now: Date = Date()) throws -> AppContainer {
        try DemoSession.makeContainer(defaults: makeDefaults(), resetDomain: DevelopmentDataMode.demoBundleID, now: now)
    }

    private func makeDefaults() -> DemoTestDefaults {
        let domain = "DevelopmentDemoTests.\(UUID().uuidString)"
        let defaults = DemoTestDefaults(domain: domain)
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        return defaults
    }

    private func amounts(in container: AppContainer) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: container.dataStore.accounts(in: container.layout.displayGroups).flatMap { account in
            account.lines.map { ($0.id, $0.data.used) }
        })
    }
}

/// Redirect domain deletion into this test's suite. Calling removePersistentDomain on an isolated
/// UserDefaults object still targets a named global domain, so the test must intercept the reset.
private final class DemoTestDefaults: UserDefaults, @unchecked Sendable {
    let domain: String
    private(set) var requestedResets: [String] = []

    init(domain: String) {
        self.domain = domain
        super.init(suiteName: domain)!
        super.removePersistentDomain(forName: domain)
    }

    override func removePersistentDomain(forName domainName: String) {
        requestedResets.append(domainName)
        super.removePersistentDomain(forName: domain)
    }
}
#endif
