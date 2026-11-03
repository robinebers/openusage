import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarStripGateTests: XCTestCase {
    func testChangedStripIsShown() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        gate.show(makeContent(value: "42%"), using: { shown.append($0) })
        gate.show(makeContent(value: "43%"), using: { shown.append($0) })
        gate.show(makeContent(value: "43%"), using: { shown.append($0) })
        XCTAssertEqual(shown, [makeContent(value: "42%"), makeContent(value: "43%")])
    }

    func testAChangedOverflowIsShown() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        var more = makeContent(value: "42%")
        more.overflow = 2
        gate.show(makeContent(value: "42%"), using: { shown.append($0) })
        gate.show(more, using: { shown.append($0) })
        gate.show(more, using: { shown.append($0) })
        XCTAssertEqual(shown, [makeContent(value: "42%"), more])
    }

    private func makeContent(value: String) -> MenuBarContent {
        MenuBarContent(items: [MenuBarContent.Item(
            id: "claude.session",
            provider: Provider(id: "claude", kind: .claude),
            label: "Session",
            shortLabel: "Session",
            value: value
        )])
    }
}
