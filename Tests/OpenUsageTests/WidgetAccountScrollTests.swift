import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class WidgetAccountScrollTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    func testWidgetClickRevealsAnOffscreenSecondAccount() async throws {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults
        )
        let first = Provider(id: "codex@first", kind: .codex, accountLabel: "First")
        let second = Provider(id: "codex@second", kind: .codex, accountLabel: "Second")
        let descriptors = [first, second].flatMap { provider in
            (0..<(provider.id == first.id ? 10 : 1)).map { index in
                WidgetDescriptor.percent(key: "metric\(index)", provider: provider, title: "Metric \(index)")
            }
        }
        let registry = WidgetRegistry(providers: [first, second], descriptors: descriptors)
        let layout = LayoutStore(registry: registry, defaults: defaults)
        let dataStore = WidgetDataStore.forTesting([], registry: registry, defaults: defaults)
        for provider in [first, second] {
            dataStore.snapshots[provider.id] = ProviderSnapshot(
                provider: provider, plan: "Pro",
                lines: descriptors.filter { $0.providerID == provider.id }.map {
                    .progress(label: $0.metricLabel, used: 30, limit: 100, format: .percent)
                }
            )
        }
        let frames = Frames()
        let view = DashboardView()
            .environment(container)
            .environment(layout)
            .environment(dataStore)
            .environment(container.renaming)
            .environment(container.popover)
            .environment(UpdaterController())
            .environment(\.reduceAnimations, true)
            .onPreferenceChange(ReorderFramePreferenceKey.self) { frames.byID = $0 }
            .frame(width: PanelMetrics.width, height: 220)
        let host = show(view, size: CGSize(width: PanelMetrics.width, height: 220)).host
        try await settle(host)
        let scroll = try XCTUnwrap(scrollView(in: host))
        let initialOffset = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(try XCTUnwrap(frames.byID[second.id]).minY, host.bounds.height)

        container.popover.openWidgetAccount(second.id, hasVisibleMetrics: true)
        try await settle(host)

        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initialOffset + 1, "the widget click did not scroll")
        let revealed = try XCTUnwrap(frames.byID[second.id])
        XCTAssertGreaterThanOrEqual(revealed.minY, 0)
        XCTAssertLessThan(revealed.maxY, host.bounds.height, "the selected account stayed below the viewport")
        XCTAssertNil(container.popover.dashboardFocusProviderID)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
