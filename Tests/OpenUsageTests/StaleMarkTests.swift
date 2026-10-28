import AppKit
import XCTest
@testable import OpenUsage

@MainActor
final class StaleMarkTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let provider = Provider(id: "test", kind: .claude)

    func testAnOldSnapshotHeldByABackoffSetsTheMarkUntilARefreshSucceeds() async {
        let clock = TestClock(start)
        let failure = RefreshFailure(message: "Refused", kind: .refused)
        let runtime = StubRuntime(provider: provider, descriptors: []) { [self] count in
            count == 1 ? .failure(failure) : .success(ok(at: clock.now))
        }
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })

        await store.refreshAll()
        XCTAssertFalse(store.hasStaleAccount, "current numbers")

        clock.set(start.addingTimeInterval(60))
        await store.refreshAll(force: true)
        XCTAssertNotNil(store.backoffs["test"])
        XCTAssertFalse(store.hasStaleAccount, "a failure on current numbers is not stale yet")

        let redrawn = TestSwitch(false)
        withObservationTracking { _ = store.hasStaleAccount } onChange: { redrawn.value = true }
        clock.set(start.addingTimeInterval(RefreshSetting.interval))
        XCTAssertFalse(store.hasStaleAccount, "the mark follows the refresh passes, not the clock")
        await store.refreshAll()
        XCTAssertNotNil(store.backoffs["test"], "the pass backed off and wrote no snapshot")
        XCTAssertTrue(store.hasStaleAccount, "the numbers outlived their slot while the backoff holds")
        XCTAssertTrue(redrawn.value, "the backed-off pass still re-evaluates the strip")

        clock.set(store.backoffs["test"]!.retryAt)
        await store.refreshAll()
        XCTAssertNil(store.backoffs["test"])
        XCTAssertFalse(store.hasStaleAccount, "a successful refresh clears the mark")
    }

    func testAnAccountThatIsOnlyRefreshingShowsNoMark() async {
        let clock = TestClock(start)
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [])
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now }, providerRefreshTimeout: 0.2)
        store.snapshots["test"] = ok(at: start.addingTimeInterval(-3600))

        let refresh = Task { await store.refreshAll(force: true) }
        for _ in 0..<1_000 where store.refreshingProviderIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(store.refreshingProviderIDs, ["test"])
        XCTAssertFalse(store.hasStaleAccount, "old numbers mid-refresh, with no failure yet")

        await refresh.value
        XCTAssertTrue(store.hasStaleAccount, "the refresh timed out, so the old numbers are held by its backoff")
    }

    func testAStaleStripDrawsAtHalfStrength() throws {
        let metric = MenuBarContent.Metric(id: "test.session", label: "Session", value: "42%")
        let current = MenuBarContent(groups: [MenuBarContent.Group(provider: provider, metrics: [metric])])
        var stale = current
        stale.isStale = true
        XCTAssertNotEqual(current, stale, "the strip gate redraws when only the mark changes")

        let currentAlpha = try maxAlpha(XCTUnwrap(MenuBarStripRenderer.image(for: current)))
        let staleAlpha = try maxAlpha(XCTUnwrap(MenuBarStripRenderer.image(for: stale)))
        XCTAssertEqual(currentAlpha, 255)
        XCTAssertEqual(Double(staleAlpha), 127.5, accuracy: 2)
        XCTAssertEqual(current.accessibilityText, "Claude Session 42%")
        XCTAssertEqual(stale.accessibilityText, "Claude Session 42%, waiting for a provider")
    }

    func testTheAppIconStandingInForAnEmptyStripDimsToo() throws {
        let empty = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        let staleEmpty = MenuBarContentBuilder.build(groups: [], isStale: true, data: { $0.sample })
        XCTAssertNil(MenuBarStripRenderer.image(for: staleEmpty), "an empty strip falls back to the app icon")

        XCTAssertEqual(try maxAlpha(MenuBarStripRenderer.appIcon(for: empty)), 255)
        let dimmed = MenuBarStripRenderer.appIcon(for: staleEmpty)
        XCTAssertTrue(dimmed.isTemplate)
        XCTAssertEqual(Double(try maxAlpha(dimmed)), 127.5, accuracy: 2)
    }

    private func ok(at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 12, limit: 100, format: .percent)],
            refreshedAt: date
        )
    }

    private func maxAlpha(_ image: NSImage) throws -> UInt8 {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var alpha = [UInt8](repeating: 0, count: cgImage.width * cgImage.height)
        let context = try XCTUnwrap(CGContext(
            data: &alpha, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return alpha.max() ?? 0
    }
}
