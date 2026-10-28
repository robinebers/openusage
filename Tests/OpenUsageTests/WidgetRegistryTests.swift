import XCTest
@testable import OpenUsage

final class WidgetRegistryTests: XCTestCase {
    private func provider(_ id: String) -> Provider {
        Provider(id: id, kind: ProviderKind(rawValue: id)!)
    }

    private func descriptor(_ key: String, provider: Provider) -> WidgetDescriptor {
        WidgetDescriptor(
            provider: provider,
            key: key,
            metricLabel: key,
            sample: WidgetData(title: key, kind: .percent, used: 0, limit: 100)
        )
    }

    func testLookupsReturnExpectedEntries() {
        let claude = provider("claude")
        let codex = provider("codex")
        let session = descriptor("session", provider: claude)
        let weekly = descriptor("weekly", provider: claude)
        let codexSession = descriptor("session", provider: codex)
        let registry = WidgetRegistry(
            providers: [claude, codex],
            descriptors: [session, weekly, codexSession]
        )

        XCTAssertEqual(registry.descriptor(id: "claude.weekly"), weekly)
        XCTAssertNil(registry.descriptor(id: "missing"))
        XCTAssertEqual(registry.provider(id: "codex"), codex)
        XCTAssertNil(registry.provider(id: "missing"))
    }

    func testDescriptorsForProviderPreserveOriginalOrder() {
        let claude = provider("claude")
        let codex = provider("codex")
        let c1 = descriptor("session", provider: claude)
        let x1 = descriptor("session", provider: codex)
        let c2 = descriptor("weekly", provider: claude)
        let x2 = descriptor("weekly", provider: codex)
        let c3 = descriptor("extra", provider: claude)
        let registry = WidgetRegistry(
            providers: [claude, codex],
            descriptors: [c1, x1, c2, x2, c3]
        )

        XCTAssertEqual(
            registry.descriptors(for: "claude").map(\.id),
            ["claude.session", "claude.weekly", "claude.extra"]
        )
        XCTAssertEqual(
            registry.descriptors(for: "codex").map(\.id),
            ["codex.session", "codex.weekly"]
        )
        XCTAssertEqual(registry.descriptors(for: "missing"), [])
    }

    func testProviderOrderFiltersUnknownAndAppendsNewProviders() {
        let claude = provider("claude")
        let codex = provider("codex")
        let cursor = provider("cursor")
        let registry = WidgetRegistry(providers: [claude, codex, cursor], descriptors: [])

        XCTAssertEqual(
            registry.orderedProviderIDs(savedOrder: ["codex", "removed", "claude"]),
            ["codex", "claude", "cursor"]
        )
    }
}
