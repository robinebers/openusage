import XCTest
@testable import OpenUsage

/// Needs Attention, the account page's problem card, and the All Usage warning wait for a refresh that fails.
@MainActor
final class LaunchAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claude = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")

    private func weekly(_ provider: Provider) -> WidgetDescriptor {
        .percent(key: "weekly", provider: provider, title: "Weekly")
    }

    private func reading(_ provider: Provider, at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, plan: nil, lines: [.percent("Weekly", 10)], refreshedAt: date)
    }

    /// A launch with Claude's reading from the last session, three hours old, and ChatGPT never read.
    private func launch(claude answers: [Result<ProviderSnapshot, RefreshFailure>]) -> WidgetDataStore {
        let defaults = isolatedDefaults()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.save([claude.id: reading(claude, at: now.addingTimeInterval(-3 * 3600))])
        let runtimes = [
            StubRuntime(provider: claude, descriptors: [weekly(claude)], results: answers),
            StubRuntime(provider: chatGPT, descriptors: [weekly(chatGPT)], snapshot: reading(chatGPT, at: now)),
        ]
        return WidgetDataStore.forTesting(runtimes, cache: cache, defaults: defaults, now: { self.now })
    }

    /// The accounts flagged anywhere: Priority's Needs Attention, the account page, and All Usage's warning.
    private func flagged(_ store: WidgetDataStore) -> [String] {
        let groups = [claude, chatGPT].map { ProviderMetrics(provider: $0, metrics: [weekly($0)]) }
        let listed = store.priorityBoard(in: groups, now: now).notices.map(\.provider.id)
        let pages = [claude, chatGPT].map(\.id).filter { store.problem(for: $0) != nil || store.notice(for: $0) != nil }
        XCTAssertEqual(listed, pages, "Priority and the account pages agree")
        return pages
    }

    func testALaunchFlagsNoAccountBeforeARefreshFails() {
        let store = launch(claude: [.success(reading(claude, at: now))])
        XCTAssertEqual(flagged(store), [])
        XCTAssertEqual(store.stalenessHint(for: claude.id), "Last updated 3h ago", "the quiet clock still dates the old values")
        let groups = [claude, chatGPT].map { ProviderMetrics(provider: $0, metrics: [weekly($0)]) }
        XCTAssertEqual(store.priorityBoard(in: groups, now: now).waiting.map(\.id), [chatGPT.id])
    }

    func testAFailedRefreshIsFlaggedAtOnceBesideAPendingAccountAndClearsWhenItRecovers() async {
        let failure = RefreshFailure(message: "Sign in to Claude again.", kind: .refused)
        let store = launch(claude: [.failure(failure), .success(reading(claude, at: now))])

        await store.refresh(providerID: claude.id, force: true)
        XCTAssertEqual(flagged(store), [claude.id], "only the account that failed, not the one still loading")
        XCTAssertEqual(store.problem(for: claude.id), failure.message)

        await store.refresh(providerID: claude.id, force: true)
        XCTAssertEqual(flagged(store), [])
    }
}
