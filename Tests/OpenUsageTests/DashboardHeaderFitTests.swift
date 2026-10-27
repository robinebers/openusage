import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// Robin's own accounts at the 340 pt panel, as the dashboard hosts them: every account's caption,
/// name and plan, sits whole inside its card with room for the status glyph, and nothing is ever
/// truncated or shrunk. The caption is hosted in a window at the card's inner width and its name and
/// plan are measured in pixels against the same text drawn alone, so a truncated name, which draws
/// narrower, fails here. Every card captions every account, so this is the proof the rule fits the panel.
@MainActor
final class DashboardHeaderFitTests: QuietWindowTestCase {
    /// What a caption has to draw in: the card less its padding on each side.
    private let width = DashboardGrid.cardWidth - 2 * DashboardGrid.cardPadding

    /// Every one of Robin's accounts: the name starts at the caption's inset and ends where the name alone
    /// would, the plan ends at the inset before the card's edge as wide as the plan alone, at least 8 pt
    /// between them with nothing in between, the caption one Subheadline line, and the line still has
    /// room for the warning glyph after the name.
    func testRobinsCaptionsFitWhole() async throws {
        let captions: [(ProviderKind, String, String)] = [
            (.grok, "rob@sunstory.com", "SuperGrok Heavy"), (.cursor, "rob@sunstory.com", "Ultra"),
            (.codex, "sam@hey.com", "Plus"), (.codex, "Sunstory", "Pro 200"), (.opencodeGo, "OpenCode", "Go"),
            (.claude, "Personal", "Max 20x"), (.ollama, "Ollama", "Free"), (.openrouter, "OpenRouter", "Pay-as-you-go"),
            (.claude, "Attention Machine 1", "Team 5x"), (.claude, "Attention Machine 2", "Team 5x"),
        ]
        let inset = DashboardGrid.inset
        let planEnd = width - inset
        for (kind, name, plan) in captions {
            let label = "\(name) · \(plan)"
            let account = account(kind, name)

            let warned = DashboardAccountCaption(account: account, plan: plan, status: AccountStatus(notice: "Refresh failed"))
            let asked = NSHostingView(rootView: warned.fixedSize().environment(AccountRenameStore?.none)).fittingSize.width
            XCTAssertLessThanOrEqual(asked, width, "\(label) asks \(asked) of \(width) pt")

            let nameAlone = try await Ink(Text(name).font(DashboardGrid.captionFont).foregroundStyle(.secondary).fixedSize().padding(20), in: self)
            let planAlone = try await Ink(Text(plan).font(DashboardGrid.planFont).foregroundStyle(.secondary).fixedSize().padding(20), in: self)
            let nameWidth = try XCTUnwrap(nameAlone.span()).width
            let planWidth = try XCTUnwrap(planAlone.span()).width
            let caption = try await Ink(DashboardAccountCaption(account: account, plan: plan), in: self, width: width)
            XCTAssertEqual(CGFloat(caption.height) / caption.scale, DashboardGrid.captionHeight, accuracy: 1, label)

            let title = try XCTUnwrap(caption.span(from: 0, to: inset + nameWidth + 4), "\(label): no name drawn")
            XCTAssertEqual(title.first, inset, accuracy: 1.5, "\(label): the name doesn't start at the caption's inset")
            XCTAssertEqual(title.last, inset + nameWidth, accuracy: 1.5, "\(label): the name is cut")
            let drawnPlan = try XCTUnwrap(caption.span(from: planEnd - planWidth - 2, to: planEnd + 2), "\(label): no plan drawn")
            XCTAssertEqual(drawnPlan.last, planEnd, accuracy: 1.5, "\(label): the plan doesn't end at the inset before the edge")
            XCTAssertEqual(drawnPlan.width, planWidth, accuracy: 1.5, "\(label): the plan is cut")
            XCTAssertLessThanOrEqual(title.last + DashboardGrid.columnGap, drawnPlan.first + 1, "\(label): the name runs into the plan")
            XCTAssertNil(caption.span(from: title.last + 1, to: drawnPlan.first - 1), "\(label): something sits between the name and the plan")
        }
    }

    private func account(_ kind: ProviderKind, _ name: String) -> DashboardAccount {
        DashboardAccount(provider: Provider(id: "\(kind.rawValue)@1", displayName: kind.displayName,
                                            icon: kind.rawValue, accountLabel: name), lines: [])
    }
}

/// A view hosted in a quiet window, in light mode, read back as pixels with the top row first.
private struct Ink {
    struct Span {
        /// The x of the first and last ink, in points.
        let first: CGFloat
        let last: CGFloat
        var width: CGFloat { last - first }
    }

    let width: Int
    let height: Int
    let scale: CGFloat
    private let pixels: [UInt8]
    private let bytesPerRow: Int
    private let samples: Int

    /// Hosts `content` at `width` (its own width when nil), lets it lay out, and reads its pixels.
    @MainActor
    init(_ content: some View, in testCase: XCTestCase, width: CGFloat? = nil) async throws {
        let view = content
            .frame(width: width)
            .background(Color.white)
            .environment(AccountRenameStore?.none)
            .environment(\.hoverTooltipsDisabled, true)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = QuietWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        QuietTestProcess.show(window, in: testCase)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        self.width = rep.pixelsWide
        self.height = rep.pixelsHigh
        scale = CGFloat(rep.pixelsWide) / host.bounds.width
        bytesPerRow = rep.bytesPerRow
        samples = rep.samplesPerPixel
        let data = try XCTUnwrap(rep.bitmapData)
        pixels = Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    /// Ink is a painted pixel that is clearly not the white background.
    private func isInk(_ x: Int, _ y: Int) -> Bool {
        let p = y * bytesPerRow + x * samples
        guard samples < 4 || pixels[p + 3] > 200 else { return false }
        return (0..<min(samples, 3)).contains { pixels[p + $0] < 215 }
    }

    /// The first and last ink between two x positions in points (the whole width by default), or `nil`
    /// when there is none.
    func span(from start: CGFloat = 0, to end: CGFloat? = nil) -> Span? {
        let columns = max(0, Int(start * scale))..<min(width, end.map { Int($0 * scale) } ?? width)
        let inked = columns.filter { x in (0..<height).contains { isInk(x, $0) } }
        guard let first = inked.first, let last = inked.last else { return nil }
        return Span(first: CGFloat(first) / scale, last: CGFloat(last + 1) / scale)
    }
}
