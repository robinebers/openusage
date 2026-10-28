import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The dashboard as the app hosts it — `WidgetGroupedListView` with its stores, in an `NSHostingView`
/// inside a window — keeps the grid's heights: 20 pt per row, one Subheadline line per caption, one
/// Headline line per header, a caption over every account, one or several, and nothing between two rows of one account. The share image draws the static
/// `DashboardAccountRows`, so a height the live tree adds around a row shows only here.
@MainActor
final class DashboardLiveLayoutTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private let codex = Provider(id: "codex", displayName: "Codex", icon: "codex", accountLabel: "Sunstory")
    private let personal = Provider(id: "claude@1", displayName: "Claude", icon: "claude", accountLabel: "Personal")
    private let work = Provider(id: "claude@2", displayName: "Claude", icon: "claude", accountLabel: "Work")

    private func descriptor(_ provider: Provider, _ metric: String, _ title: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: "\(provider.id).\(metric)", providerID: provider.id, metricLabel: title,
            sample: WidgetData(title: title, kind: .percent, used: 0, limit: 100)
        )
    }

    /// Codex alone with three rows, then Claude with two accounts of two rows each, every row with a
    /// reset so it takes the live row's clock.
    private func host() async throws -> (host: NSView, frames: Frames) {
        let defaults = isolatedDefaults()
        let registry = WidgetRegistry(
            providers: [codex, personal, work],
            descriptors: [
                descriptor(codex, "session", "Session"), descriptor(codex, "weekly", "Weekly"), descriptor(codex, "spark", "Spark"),
                descriptor(personal, "session", "Session"), descriptor(personal, "weekly", "Weekly"),
                descriptor(work, "session", "Session"), descriptor(work, "weekly", "Weekly"),
            ]
        )
        let container = await AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let dataStore = WidgetDataStore.forTesting([], registry: registry, defaults: defaults)
        for provider in [codex, personal, work] {
            dataStore.snapshots[provider.id] = ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName, plan: "Pro",
                lines: ["Session", "Weekly", "Spark"].map {
                    .progress(label: $0, used: 30, limit: 100, format: .percent, resetsAt: Date().addingTimeInterval(3600), periodDurationMs: 5 * 3_600_000)
                }
            )
        }
        XCTAssertEqual(layout.displayGroups.map(\.provider.id), ["codex", "claude@1", "claude@2"])

        let frames = Frames()
        let view = WidgetGroupedListView(reorderSpaceName: "test", reorderLift: .constant(nil))
            .coordinateSpace(name: "test")
            .onPreferenceChange(ReorderFramePreferenceKey.self) { frames.byID = $0 }
            .frame(width: PanelMetrics.width - 2 * PanelMetrics.margin)
            .environment(container)
            .environment(layout)
            .environment(dataStore)
            .environment(container.renaming)
            .environment(\.colorScheme, .light)
        let host = show(view, in: .borderless).host
        try await Task.sleep(for: .milliseconds(300))
        return (host, frames)
    }

    private func frame(_ frames: Frames, _ id: String, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(frames.byID[id], "no frame for \(id) in \(frames.byID.keys.sorted())", line: line)
    }

    func testLiveRowsCaptionsAndHeadersKeepTheGridsHeights() async throws {
        let (host, frames) = try await host()
        let grid = DashboardGrid.self
        let codexCard = grid.headerHeight + grid.headerGap + 2 * grid.cardPadding + grid.captionHeight + 3 * grid.rowHeight
        let claudeCard = grid.headerHeight + grid.headerGap + 2 * grid.cardPadding + 2 * (grid.captionHeight + 2 * grid.rowHeight) + grid.accountSpacing

        for id in ["codex.session", "codex.weekly", "codex.spark", "claude@1.session", "claude@1.weekly", "claude@2.session", "claude@2.weekly"] {
            XCTAssertEqual(try frame(frames, id).height, grid.rowHeight, accuracy: 0.5, "\(id) isn't a 20 pt row")
        }
        for (above, below) in [("codex.session", "codex.weekly"), ("codex.weekly", "codex.spark"), ("claude@1.session", "claude@1.weekly")] {
            XCTAssertEqual(try frame(frames, below).minY - frame(frames, above).minY, grid.rowHeight, accuracy: 0.5, "something sits between \(above) and \(below)")
        }
        XCTAssertEqual(try frame(frames, "family:codex").height, codexCard, accuracy: 0.5, "a header and a card of a caption over three rows")
        XCTAssertEqual(try frame(frames, "family:claude").height, claudeCard, accuracy: 0.5, "a header and two accounts, each a caption and two rows")
        XCTAssertEqual(try frame(frames, "codex").minY - frame(frames, "family:codex").minY, grid.headerHeight + grid.headerGap + grid.cardPadding, accuracy: 0.5, "the header isn't one Headline line")
        XCTAssertEqual(try frame(frames, "codex").height, grid.captionHeight + 3 * grid.rowHeight, accuracy: 0.5, "Codex's sole account isn't a caption over three rows")
        for account in ["claude@1", "claude@2"] {
            XCTAssertEqual(try frame(frames, account).height, grid.captionHeight + 2 * grid.rowHeight, accuracy: 0.5, "\(account) isn't a caption over two rows")
            XCTAssertEqual(try frame(frames, "\(account).session").minY - frame(frames, account).minY, grid.captionHeight, accuracy: 0.5, "\(account)'s caption isn't one Subheadline line")
        }
        XCTAssertEqual(host.fittingSize.height, codexCard + grid.sectionSpacing + claudeCard, accuracy: 0.5)
    }
}
