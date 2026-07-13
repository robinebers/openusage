import XCTest
@testable import OpenUsage

final class WidgetRegistryTests: XCTestCase {
    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
    }

    private func descriptor(_ id: String, provider: Provider) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: id,
            sample: WidgetData(title: id, icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
    }

    func testLookupsReturnExpectedEntries() {
        let claude = provider("claude")
        let codex = provider("codex")
        let session = descriptor("claude.session", provider: claude)
        let weekly = descriptor("claude.weekly", provider: claude)
        let codexSession = descriptor("codex.session", provider: codex)
        let registry = WidgetRegistry(
            providers: [claude, codex],
            descriptors: [session, weekly, codexSession]
        )

        XCTAssertEqual(registry.descriptor(id: "claude.weekly"), weekly)
        XCTAssertNil(registry.descriptor(id: "missing"))
        XCTAssertEqual(registry.provider(id: "codex"), codex)
        XCTAssertNil(registry.provider(id: "missing"))
    }

    /// The precomputed per-provider list must preserve the original `descriptors` array order — the UI's
    /// metric ordering depends on it, so this guards the O(1) refactor against silent reordering.
    func testDescriptorsForProviderPreserveOriginalOrder() {
        let claude = provider("claude")
        let codex = provider("codex")
        // Interleave two providers so a naive grouping that didn't preserve order could still pass for a
        // single contiguous run.
        let c1 = descriptor("claude.session", provider: claude)
        let x1 = descriptor("codex.session", provider: codex)
        let c2 = descriptor("claude.weekly", provider: claude)
        let x2 = descriptor("codex.weekly", provider: codex)
        let c3 = descriptor("claude.extra", provider: claude)
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

    /// With duplicate ids, both single-entry lookups resolve to the first match — matching the original
    /// `.first { $0.id == id }` accessors so the refactor can't change which descriptor/provider wins.
    func testDuplicateIDsResolveToFirstMatch() {
        let p1 = Provider(id: "dup", displayName: "First", icon: .providerMark("a"))
        let p2 = Provider(id: "dup", displayName: "Second", icon: .providerMark("b"))
        let d1 = WidgetDescriptor(id: "dup.m", providerID: "dup", metricLabel: "First",
                                  sample: WidgetData(title: "First", icon: .providerMark("a"), kind: .count, used: 1, limit: nil))
        let d2 = WidgetDescriptor(id: "dup.m", providerID: "dup", metricLabel: "Second",
                                  sample: WidgetData(title: "Second", icon: .providerMark("b"), kind: .count, used: 2, limit: nil))
        let registry = WidgetRegistry(providers: [p1, p2], descriptors: [d1, d2])

        XCTAssertEqual(registry.provider(id: "dup")?.displayName, "First")
        // WidgetDescriptor equality is id-only; compare the sample to prove the first one wins.
        XCTAssertEqual(registry.descriptor(id: "dup.m")?.sample.title, "First")
    }
}
