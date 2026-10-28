import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarStripGateTests: XCTestCase {
    func testUnchangedStripIsNotShownAgain() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        gate.show(makeContent(value: "42%"), using: { shown.append($0) })
        gate.show(makeContent(value: "42%"), using: { shown.append($0) })
        XCTAssertEqual(shown, [makeContent(value: "42%")])
    }

    func testChangedStripIsShown() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        gate.show(makeContent(value: "42%"), using: { shown.append($0) })
        gate.show(makeContent(value: "43%"), using: { shown.append($0) })
        gate.show(makeContent(value: "43%"), using: { shown.append($0) })
        XCTAssertEqual(shown, [makeContent(value: "42%"), makeContent(value: "43%")])
    }

    private func makeContent(value: String) -> MenuBarContent {
        let metric = MenuBarContent.Metric(id: "claude.session", label: "Session", value: value)
        return MenuBarContent(
            groups: [MenuBarContent.Group(
                provider: Provider(id: "claude", kind: .claude),
                metrics: [metric]
            )]
        )
    }
}
