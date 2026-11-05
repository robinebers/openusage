import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class UsageBreakdownDetailTests: XCTestCase {
    private static let provider = Provider(id: "codex", kind: .codex)

    private func breakdown(_ values: [UsageMeasure: Double]) throws -> UsageBreakdown {
        var history = UsageHistory(calendar: .current, asOf: Date())
        history.days[Calendar.current.startOfDay(for: Date())] = UsageDay(totals: UsageTotals(values: values))
        return try XCTUnwrap(UsageBreakdown(.today, in: history))
    }

    func testTheWidestTokenLegendFitsInsideThePopover() throws {
        let wide = try breakdown([
            .spend: 857.56, .tokens: 991.9e6 * 5, .inputTokens: 824.2e6, .cacheReadTokens: 999.9e6,
            .cacheWriteTokens: 891.9e6, .outputTokens: 793.6e6, .reasoningTokens: 693.6e6,
        ])
        let content = UsageBreakdownContent(breakdown: wide, provider: Self.provider, figure: .cost).fixedSize()
        let needed = NSHostingView(rootView: content).fittingSize.width
        XCTAssertLessThanOrEqual(needed, UsageBreakdownDetail.width - 2 * UsageBreakdownDetail.padding)
    }

    /// A centered message too long for one line wraps onto lines of about equal width, not a long line and a lone word.
    func testTheEmptyMessageWrapsOntoBalancedLines() throws {
        let provider = Provider(id: "openrouter", kind: .openrouter)
        let detail = UsageBreakdownDetail(
            content: .reported(try breakdown([.credits: 0])), provider: provider, animates: false,
            onCopy: { _, _ in false }, onHoverChange: { _ in }
        )
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: detail)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let leading = Int((UsageBreakdownDetail.padding + 4) * renderer.scale)
        let widest = (0..<rep.pixelsHigh).compactMap { y -> Int? in
            let inked = (0..<rep.pixelsWide).filter { x in rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.brightnessComponent < 0.5 }
            guard let first = inked.first, let last = inked.last, first > leading else { return nil }
            return last - first
        }.max() ?? 0

        let message = "\(provider.displayName) didn't report any data for this range."
        let oneLine = NSHostingView(rootView: Text(message).font(.system(size: 13, weight: .semibold)).fixedSize()).fittingSize.width
        XCTAssertGreaterThan(oneLine, UsageBreakdownDetail.width - 2 * UsageBreakdownDetail.padding, "the message needs two lines")
        XCTAssertLessThan(CGFloat(widest) / renderer.scale, oneLine / 2 + 24, "its longest line is about half the message")
    }

    func testOnlyARangeOfZerosIsEmpty() throws {
        let zeros = try breakdown([.credits: 0, .tokens: 0])
        XCTAssertTrue(zeros.isEmpty)

        let spendOnly = try breakdown([.spend: 0, .byokSpend: 0])
        XCTAssertTrue(spendOnly.isEmpty, "a zero charge and nothing else leaves nothing to show")

        let totals = try breakdown([.credits: 0, .tokens: 766_600_000])
        XCTAssertFalse(totals.isEmpty, "tokens without a charge are still usage")
    }
}
