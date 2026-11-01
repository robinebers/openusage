import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardLiveLayoutTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private let codex = Provider(id: "codex", kind: .codex, accountLabel: "Sunstory")
    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let work = Provider(id: "claude@2", kind: .claude, accountLabel: "Work")

    private func descriptor(_ provider: Provider, _ metric: String, _ title: String) -> WidgetDescriptor {
        WidgetDescriptor(
            provider: provider, key: metric, metricLabel: title,
            sample: WidgetData(title: title, kind: .percent, used: 0, limit: 100)
        )
    }

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
        let container = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
        let layout = LayoutStore(registry: registry, defaults: defaults)
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
            .environment(container.popover)
            .environment(\.colorScheme, .light)
        let host = show(view, in: .borderless).host
        try await Task.sleep(for: .milliseconds(300))
        return (host, frames)
    }

    private func frame(_ frames: Frames, _ id: String, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(frames.byID[id], "no frame for \(id) in \(frames.byID.keys.sorted())", line: line)
    }

    func testLiveRowsCaptionsAndHeadersFollowTheGrid() async throws {
        let (host, frames) = try await host()
        let grid = DashboardGrid.self
        let row = try frame(frames, "codex.session").height
        XCTAssertGreaterThan(row, 16 + grid.barGap + grid.barHeight - 1, "a limit isn't a line of text over its bar")
        let codexRows = 3 * row + 2 * grid.limitGap
        let claudeAccount = grid.captionHeight + grid.captionGap + 2 * row + grid.limitGap
        let codexCard = grid.headerHeight + grid.headerGap + 2 * grid.cardPadding + codexRows
        let claudeCard = grid.headerHeight + grid.headerGap + 2 * grid.cardPadding + 2 * claudeAccount + grid.accountSpacing

        for id in ["codex.session", "codex.weekly", "codex.spark", "claude@1.session", "claude@1.weekly", "claude@2.session", "claude@2.weekly"] {
            XCTAssertEqual(try frame(frames, id).height, row, accuracy: 0.5, id)
        }
        for (above, below) in [("codex.session", "codex.weekly"), ("codex.weekly", "codex.spark"), ("claude@1.session", "claude@1.weekly")] {
            XCTAssertEqual(try frame(frames, below).minY - frame(frames, above).maxY, grid.limitGap, accuracy: 0.5, "\(above) and \(below) aren't 9 pt apart")
        }
        XCTAssertEqual(try frame(frames, "family:codex").height, codexCard, accuracy: 0.5, "a header and a card of three limits, with no caption")
        XCTAssertEqual(try frame(frames, "family:claude").height, claudeCard, accuracy: 0.5, "a header and two accounts, each a caption and two limits")
        XCTAssertEqual(try frame(frames, "codex").minY - frame(frames, "family:codex").minY, grid.headerHeight + grid.headerGap + grid.cardPadding, accuracy: 0.5)
        XCTAssertEqual(try frame(frames, "codex.session").minY, try frame(frames, "codex").minY, accuracy: 0.5, "a sole account has a caption")
        XCTAssertEqual(try frame(frames, "claude@2").minY - frame(frames, "claude@1").maxY, 20, accuracy: 0.5, "accounts aren't 20 pt apart")
        for account in ["claude@1", "claude@2"] {
            XCTAssertEqual(try frame(frames, account).height, claudeAccount, accuracy: 0.5, account)
            XCTAssertEqual(try frame(frames, "\(account).session").minY - frame(frames, account).minY, grid.captionHeight + grid.captionGap, accuracy: 0.5, account)
        }
        XCTAssertEqual(host.fittingSize.height, codexCard + grid.sectionSpacing + claudeCard, accuracy: 0.5)
    }
}
