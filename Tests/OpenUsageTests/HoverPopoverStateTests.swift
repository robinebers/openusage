import XCTest
@testable import OpenUsage

@MainActor
final class HoverPopoverStateTests: XCTestCase {
    func testAPinnedPopoverStaysThroughHoverOutUntilDismissed() async throws {
        let state = HoverPopoverState(revealDelay: .zero, hideGrace: .zero)
        state.inlineHover(true)
        try await settle(until: { state.isPresented })

        state.setPinned(true)
        state.inlineHover(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(state.isPresented, "a pinned popover survives the pointer leaving its row")

        state.dismiss()
        XCTAssertFalse(state.isPresented)
    }

    func testUnpinningAfterHoverOutHidesThePopover() async throws {
        let state = HoverPopoverState(revealDelay: .zero, hideGrace: .zero)
        state.inlineHover(true)
        try await settle(until: { state.isPresented })
        state.setPinned(true)
        state.inlineHover(false)

        state.setPinned(false)

        try await settle(until: { !state.isPresented })
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}
