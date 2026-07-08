import XCTest
@testable import OpenUsage

/// The in-popover screen mode (dashboard / Customize / Settings) and its `isEditing` bridge,
/// which older call sites still drive Customize through.
@MainActor
final class PopoverScreenTests: XCTestCase {
    func testStartsOnDashboard() {
        let store = makeStore("Default")
        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertFalse(store.isEditing)
    }

    func testIsEditingBridgesCustomizeScreen() {
        let store = makeStore("Bridge")

        store.isEditing = true
        XCTAssertEqual(store.screen, .customize)

        store.isEditing = false
        XCTAssertEqual(store.screen, .dashboard)
    }

    func testSettingsScreenIsNotEditing() {
        let store = makeStore("Settings")

        store.screen = .settings
        XCTAssertFalse(store.isEditing)
    }

    func testScreensReplaceEachOther() {
        let store = makeStore("Switch")

        store.screen = .customize
        store.screen = .settings
        XCTAssertEqual(store.screen, .settings)
        XCTAssertFalse(store.isEditing)

        store.screen = .customize
        XCTAssertTrue(store.isEditing)
    }

    private func makeStore(_ name: String) -> LayoutStore {
        let defaults = makeScratchDefaults(suiteName: "OpenUsageTests.PopoverScreen.\(name).\(UUID().uuidString)")
        return LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
    }
}
