import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The panel's frame has one owner, `PanelHeightController`: while the height changes, the top edge
/// stays where the status item put it and only the bottom edge moves, through slow screen switches
/// and through Return held down on the dashboard, which switches screens faster than a morph settles.
@MainActor
final class PanelTopEdgeTests: QuietWindowTestCase {
    func testTheTopEdgeStaysAtTheAnchorThroughEveryHeightChange() async throws {
        let hosted = try await hostPopover(accounts: ["Personal", "Work", "Side"])
        let popover = hosted.popover
        let panel = hosted.panel
        let controller = PanelHeightController(panel: panel, defaults: hosted.defaults) { popover.screen }
        controller.installBridge()
        addTeardownBlock { withExtendedLifetime(controller) {} }
        let button = NSRect(x: 100, y: (NSScreen.screens.map(\.frame.maxY).max() ?? 0) + 3_000, width: 20, height: 22)
        let anchorTop = (button.minY - PanelGeometry.topGap).rounded(.down)
        let recorder = FrameRecorder(panel: panel)

        func step(_ name: String, _ change: () async throws -> Void) async throws {
            recorder.mark(name)
            try await change()
            for _ in 0..<130 {
                try await Task.sleep(for: .milliseconds(10))
                recorder.sample()
            }
        }
        func open(_ name: String) async throws {
            try await step(name) {
                controller.prepareForOpening(below: button)
                popover.popoverShown = true
                hosted.host.layoutSubtreeIfNeeded()
                panel.orderFrontRegardless()
            }
        }
        func close() async throws {
            recorder.mark("close")
            controller.saveBeforeClosing()
            popover.popoverShown = false
            panel.orderOut(nil)
            controller.finishClosing()
            try await Task.sleep(for: .milliseconds(200))
        }
        for opening in 1...2 {
            try await open("open \(opening)")
            try await step("dashboard -> accounts") { popover.toggle(.accounts) }
            try await step("accounts -> dashboard") { popover.back() }
            try await step("dashboard -> settings") { popover.toggle(.settings) }
            try await step("settings -> accounts") { popover.toggle(.accounts) }
            try await step("accounts -> settings") { popover.toggle(.settings) }
            try await step("settings -> dashboard") { popover.back() }
            try await close()
        }
        try await open("open 3")
        try await step("return held") {
            for press in 0..<40 {
                if press.isMultiple(of: 2) { popover.toggle(.accounts) } else { popover.back() }
                try await Task.sleep(for: .milliseconds(80))
                recorder.sample()
            }
        }
        try await close()

        recorder.stop()
        let shown = recorder.records.filter { $0.step != "close" }
        let heights = Set(shown.map { Int($0.frame.height) })
        XCTAssertGreaterThan(heights.count, 20, "the panel never morphed: \(heights.sorted())")
        let strays = shown.filter { abs($0.frame.maxY - anchorTop) > 0.5 }
        XCTAssertTrue(strays.isEmpty, "the top edge left the anchor \(anchorTop) on \(strays.count) of \(shown.count) frames: "
            + strays.prefix(10).map { "[\($0.step)] \($0.source) h=\($0.frame.height) top=\($0.frame.maxY)" }.joined(separator: "; "))
    }

    /// SwiftUI sets the frame of a window whose content view is a hosting view (see `MenuBarPanel.host`),
    /// so the panel keeps the hosting view one level down, filling a plain container.
    func testTheHostingViewFillsAContainerAndIsNeverTheContentView() {
        let panel = QuietMenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300))
        let hosting = NSHostingController(rootView: AnyView(Color.clear))
        panel.host(hosting.view)
        XCTAssertFalse(panel.contentView === hosting.view)
        XCTAssertTrue(hosting.view.superview === panel.contentView)
        panel.setContentSize(NSSize(width: PanelMetrics.width, height: 500))
        XCTAssertEqual(hosting.view.frame, panel.contentView?.bounds)
    }
}

/// The panel's frame after every move and resize AppKit reports, plus a sample whenever asked.
@MainActor
private final class FrameRecorder {
    struct Record {
        let step: String
        let source: String
        let frame: NSRect
    }

    private(set) var records: [Record] = []
    private var step = "start"
    private let panel: NSWindow
    private var observers: [NSObjectProtocol] = []

    init(panel: NSWindow) {
        self.panel = panel
        for (name, source) in [(NSWindow.didResizeNotification, "resize"), (NSWindow.didMoveNotification, "move")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record(source) }
            })
        }
    }

    func mark(_ name: String) { step = name }
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
    func sample() { record("sample") }

    private func record(_ source: String) {
        records.append(Record(step: step, source: source, frame: panel.frame))
    }
}
