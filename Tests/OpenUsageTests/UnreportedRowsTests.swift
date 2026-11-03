import XCTest
@testable import OpenUsage

/// A time range the provider reports nothing for reads zero, so only its switch hides it.
@MainActor
final class UnreportedRowsTests: XCTestCase {
    private func refreshed(_ kind: ProviderKind, lines: [MetricLine] = []) async -> (WidgetDataStore, StubRuntime) {
        let account = Account(kind: kind, label: kind.displayName)
        let provider = AccountProviderRuntime.provider(for: account)
        let runtime = StubRuntime(provider: provider, descriptors: AccountProviderRuntime.widgetDescriptors(for: account),
                                  snapshot: ProviderSnapshot(provider: provider, plan: nil, lines: lines))
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        await store.refreshAll()
        return (store, runtime)
    }

    func testEveryRangeRowReadsZeroInItsUnitWhenTheProviderReportsNothing() async {
        var shown: [String: String] = [:]
        for kind in ProviderKind.allCases {
            let (store, runtime) = await refreshed(kind)
            for descriptor in runtime.widgetDescriptors {
                guard case .window = descriptor.historyRow else { continue }
                let data = store.data(for: descriptor)
                XCTAssertTrue(data.hasData, descriptor.kindScopedKey)
                shown[descriptor.kindScopedKey] = data.unboundedDetail
            }
        }
        XCTAssertEqual(shown, [
            "codex.today": "0 tokens", "codex.yesterday": "0 tokens", "codex.last30": "0 tokens",
            "cursor.today": "$0 · 0 tokens", "cursor.yesterday": "$0 · 0 tokens", "cursor.last30": "$0 · 0 tokens",
            "ollama.today": "$0 · 0 tokens", "ollama.yesterday": "$0 · 0 tokens", "ollama.last30": "$0 · 0 tokens",
            "openrouter.today": "$0", "openrouter.yesterday": "$0", "openrouter.week": "$0",
            "openrouter.month": "$0", "openrouter.prior30": "$0",
        ])
    }

    func testAnEmptyRangeIsListedOnTheAccountPageShownUntilSwitchedOffAndCanBePinned() async throws {
        let (store, runtime) = await refreshed(.codex)
        let layout = LayoutStore(registry: .from([runtime]), defaults: isolatedDefaults())
        let id = runtime.provider.id
        let today = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "today" })
        func dashboardKeys() -> [String] { store.accounts(in: layout.displayGroups).flatMap(\.lines).map(\.descriptor.key) }

        XCTAssertTrue(Set(layout.orderedSupportedMetrics(for: id).map(\.key)).isSuperset(of: ["today", "yesterday", "last30"]))
        XCTAssertTrue(layout.isMetricShown(today.id), "on by default")
        XCTAssertEqual(dashboardKeys(), ["today", "yesterday", "last30"])

        XCTAssertTrue(layout.setMetric(today.id, pinned: true))
        let board = store.priorityBoard(in: layout.displayGroups, pinned: layout.state.priorityPinIDs, now: Date())
        XCTAssertEqual(board.pinned.map(\.line.descriptor.key), ["today"])
        XCTAssertEqual(board.pinned.first?.line.data.unboundedDetail, "0 tokens")

        XCTAssertTrue(layout.setMetric(today.id, shown: false))
        XCTAssertEqual(dashboardKeys(), ["yesterday", "last30"], "the switch is the only way a range row leaves")
        XCTAssertTrue(layout.orderedSupportedMetrics(for: id).contains { $0.id == today.id })
    }

    func testARangeNothingWasReadForHasDetailsWithNothingToShow() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var snapshot = ProviderSnapshot(providerID: "codex", displayName: "ChatGPT", lines: [])
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: Account(kind: .codex, label: "ChatGPT"))

        HistoryRow.append(to: &snapshot, for: descriptors, in: UsageHistory(calendar: utc, asOf: Date()))

        XCTAssertTrue(snapshot.lines.isEmpty, "the provider reported nothing")
        XCTAssertEqual(snapshot.usageBreakdowns?.keys.sorted(), ["last30", "today", "yesterday"])
        XCTAssertTrue(try XCTUnwrap(snapshot.usageBreakdowns?["today"]).isEmpty)
    }
}
