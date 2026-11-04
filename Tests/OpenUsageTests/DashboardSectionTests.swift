import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardSectionTests: QuietWindowTestCase {
    func testTheResetsPopoverStaysOpenWhenARefreshChangesTheExpiries() async throws {
        let provider = Provider(id: "claude", kind: .claude)
        var data = WidgetData(title: "Limit Resets", kind: .count, used: 2, limit: nil)
        data.showsResetExpiries = true
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]
        data.expiriesAt = [Date().addingTimeInterval(86_400), Date().addingTimeInterval(7 * 86_400)]
        let descriptor = WidgetDescriptor(provider: provider, key: "resets", metricLabel: data.title, sample: data)
        let live = LiveLine(DashboardLine(descriptor: descriptor, data: data))
        let view = ResetRow(live: live).frame(width: PanelMetrics.width - 2 * PanelMetrics.margin).animationReduction(true)
        let (window, host) = show(view)
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        func detail() -> NSWindow? { NSApp.windows.first { $0.isVisible && !shown.contains(ObjectIdentifier($0)) } }
        defer {
            HoverPopoverState.dismissAll()
            ReducedMotionPopoverController.dismissAll()
        }

        try hover(CGPoint(x: host.bounds.maxX - 12, y: host.bounds.midY), window, host)
        try await waitUntil { detail() != nil }
        let opened = try XCTUnwrap(detail())
        let oldHeight = opened.frame.height
        data.expiriesAt.removeFirst()
        data.values = [MetricValue(number: 1, kind: .count, label: "available")]
        live.line = DashboardLine(descriptor: descriptor, data: data)
        try await waitUntil { opened.frame.height < oldHeight }
        XCTAssertTrue(opened.isVisible, "A refresh after a claim dismissed the reset list")
    }
}

@MainActor @Observable private final class LiveLine {
    var line: DashboardLine
    init(_ line: DashboardLine) { self.line = line }
}

private struct ResetRow: View {
    let live: LiveLine
    var body: some View { DashboardLiveRow(line: live.line) }
}
