#if OPENUSAGE_DEVELOPMENT
import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class DevelopmentDemoTests: XCTestCase {
    private let now = Date()

    func testTheSameSeedShowsTheSameDashboard() async throws {
        let first = await dashboard(seed: 4242)
        let again = await dashboard(seed: 4242)
        XCTAssertEqual(again, first)
        let other = await dashboard(seed: 4243)
        XCTAssertNotEqual(other, first, "another seed must draw other data")
    }

    func testEveryShuffleShowsEachLimitStateOnEveryProvider() async throws {
        for seed in Array(1...30) + [DemoSession.seeds.upperBound] {
            let container = await makeContainer(seed: seed)
            let accounts = container.dataStore.accounts(in: container.layout.displayGroups)
            XCTAssertEqual(Set(accounts.map(\.provider.kind)), Set(ProviderKind.allCases), "seed \(seed)")
            XCTAssertTrue(accounts.contains { $0.provider.accountName.count > 30 }, "seed \(seed) has no long name")
            XCTAssertTrue(accounts.contains { $0.provider.accountName.contains("@") }, "seed \(seed) has no email name")
            let resets = accounts.flatMap(\.lines).compactMap(\.data.resetsAt)
            XCTAssertTrue(resets.allSatisfy { $0 >= now.addingTimeInterval(3_600) && $0 <= now.addingTimeInterval(7 * 86_400) },
                          "seed \(seed) resets outside the next hour to the next week")

            let board = container.dataStore.priorityBoard(in: container.layout.displayGroups, now: now)
            let reasons = (board.attention + board.usedUp + board.useItOrLoseIt).map(\.reason)
            let shows = { (match: (PriorityItem.Reason) -> Bool) in reasons.contains(where: match) }
            XCTAssertTrue(shows { if case .low(.warning, _, _) = $0 { true } else { false } }, "seed \(seed) has no warning")
            XCTAssertTrue(shows { if case .low(.critical, _, _) = $0 { true } else { false } }, "seed \(seed) has no critical")
            XCTAssertTrue(shows { if case .burningFast = $0 { true } else { false } }, "seed \(seed) has no Burning Fast")
            XCTAssertTrue(shows { if case .usedUp = $0 { true } else { false } }, "seed \(seed) has no Used Up")
            XCTAssertTrue(shows { $0 == .emptyBalance }, "seed \(seed) has no empty balance")
            XCTAssertTrue(shows { if case .useItOrLoseIt = $0 { true } else { false } }, "seed \(seed) has no Use It or Lose It")
            XCTAssertFalse(board.notices.isEmpty, "seed \(seed) has no account notice")
            XCTAssertTrue(board.waiting.isEmpty, "seed \(seed) left an account without a reading")
        }
    }

    func testAPinnedSeedIsReadAfterTheDemoDomainResets() {
        let defaults = makeDefaults()
        defaults.register(defaults: [DemoSession.seedKey: "4242"])
        let container = DemoSession.makeContainer(defaults: defaults, now: now)
        XCTAssertEqual(container.demo?.seed, 4242)
    }

    func testReshuffleReplacesEveryAccountInPlace() async throws {
        let container = await makeContainer(seed: 7)
        let demo = try XCTUnwrap(container.demo)
        let store = container.dataStore
        let layout = container.layout
        let before = Set(container.accounts.accounts.map(\.id))

        demo.reshuffle()
        await refresh(container)

        XCTAssertNotEqual(demo.seed, 7)
        XCTAssertTrue(container.dataStore === store)
        XCTAssertTrue(container.layout === layout)
        XCTAssertTrue(Set(container.accounts.accounts.map(\.id)).isDisjoint(with: before))
        XCTAssertEqual(Set(layout.orderedProviderIDs()), Set(container.accounts.accounts.map(\.cardID)))
        XCTAssertEqual(Set(store.snapshots.keys), Set(container.accounts.accounts.map(\.cardID)))
    }

    func testRefreshKeepsServingTheSamples() async throws {
        let container = await makeContainer(seed: 11)
        let ids = container.accounts.accounts.map(\.cardID)
        let shown = shown(in: container)

        let outcomes = await container.dataStore.refresh(providerIDs: ids, force: true)
        XCTAssertTrue(outcomes.allSatisfy { if case .refreshed = $0 { true } else { false } },
                      "a refresh must not fall through to sign-in or provider APIs")
        await container.dataStore.refreshHourlyReads()

        XCTAssertEqual(self.shown(in: container), shown)
        for id in ids { XCTAssertNil(container.dataStore.errorMessage(for: id)) }
        XCTAssertTrue(container.dataStore.backoffs.isEmpty)
    }

    func testRenameAndRemovalStayInsideTheSampleContainer() async throws {
        let container = await makeContainer(seed: 12)
        let saved = try XCTUnwrap(container.accounts.accounts.first)
        let store = container.dataStore
        let before = try XCTUnwrap(shown(in: container).first { $0.name == saved.label })

        container.accounts.rename(saved.id, to: "Sample Rename")
        _ = await store.refresh(providerID: saved.cardID, force: true)
        XCTAssertEqual(container.layout.provider(id: saved.cardID)?.accountName, "Sample Rename")
        XCTAssertEqual(shown(in: container).first { $0.name == "Sample Rename" }?.rows, before.rows)

        container.accounts.remove(saved.id)
        XCTAssertNil(container.layout.provider(id: saved.cardID))
        XCTAssertNil(store.snapshots[saved.cardID])
    }

    func testAnAccountAddedInTheDemoGetsASampleReading() async throws {
        let container = await makeContainer(seed: 13)
        let added = container.accounts.add(kind: .openrouter, label: "Added Later", credential: .apiKey("sample"))

        let outcome = await container.dataStore.refresh(providerID: added.cardID, force: true)

        if case .refreshed = outcome {} else { XCTFail("the added account has no sample reading") }
        XCTAssertNotNil(container.dataStore.snapshots[added.cardID]?.lines.first)
    }

    func testRealSignInAndResetPathsLeaveSamplesAlone() async throws {
        let container = await makeContainer(seed: 14)
        let account = try XCTUnwrap(container.accounts.accounts.first)
        let saved = try container.accounts.credential(for: account.id)

        XCTAssertNil(container.resetClaim(for: account.cardID))
        try await container.replaceCredential(.apiKey("must-not-be-saved"), for: account.cardID)

        XCTAssertEqual(try container.accounts.credential(for: account.id), saved)
    }

    func testRestartResetsOnlyTheDedicatedDemoDomain() throws {
        let defaults = makeDefaults()
        let unrelated = isolatedDefaults()
        unrelated.set("keep-real-state", forKey: "sentinel")
        let first = DemoSession.makeContainer(defaults: defaults, seed: 15, now: now)
        let original = first.accounts.accounts.map(\.label)
        let account = try XCTUnwrap(first.accounts.accounts.first)
        first.accounts.rename(account.id, to: "Temporary Name")
        defaults.set("temporary-setting", forKey: "demo-edit")

        let restarted = DemoSession.makeContainer(defaults: defaults, seed: 15, now: now)

        XCTAssertEqual(restarted.accounts.accounts.map(\.label), original)
        XCTAssertNil(defaults.string(forKey: "demo-edit"))
        XCTAssertEqual(unrelated.string(forKey: "sentinel"), "keep-real-state")
        XCTAssertFalse(defaults.requestedResets.isEmpty)
        XCTAssertTrue(defaults.requestedResets.allSatisfy { $0 == DevelopmentDataMode.demoBundleID },
                      "the session must never reset development or production preferences")
    }

    func testTheDemoHTTPClientRejectsRequestsInsteadOfSendingThem() async throws {
        do {
            _ = try await DemoHTTPClient().send(HTTPRequest(method: "GET", url: URL(string: "https://example.com/must-not-send")!))
            XCTFail("the sample HTTP boundary must reject every request")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    private struct Shown: Equatable {
        let kind: ProviderKind
        let name: String
        let plan: String?
        let notice: String?
        let rows: [DashboardRowModel]
    }

    private func dashboard(seed: Int) async -> [Shown] {
        shown(in: await makeContainer(seed: seed))
    }

    private func shown(in container: AppContainer) -> [Shown] {
        container.dataStore.accounts(in: container.layout.displayGroups).map { account in
            Shown(
                kind: account.provider.kind, name: account.provider.accountName,
                plan: container.dataStore.plan(for: account.provider.id), notice: container.dataStore.notice(for: account.provider.id),
                rows: account.lines.map { $0.data.dashboardRow(now: now) }
            )
        }
    }

    private func makeContainer(seed: Int) async -> AppContainer {
        let container = DemoSession.makeContainer(defaults: makeDefaults(), seed: seed, now: now)
        await refresh(container)
        return container
    }

    private func refresh(_ container: AppContainer) async {
        _ = await container.dataStore.refresh(providerIDs: container.accounts.accounts.map(\.cardID), force: true)
    }

    private func makeDefaults() -> DemoTestDefaults {
        let domain = "DevelopmentDemoTests.\(UUID().uuidString)"
        let defaults = DemoTestDefaults(domain: domain)
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        return defaults
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
