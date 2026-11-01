import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class UsageBreakdownDetailTests: XCTestCase {
    private static let provider = Provider(id: "codex", kind: .codex)

    private func breakdown(_ values: [UsageMeasure: Double], models: [String: UsageTotals]? = nil) throws -> UsageBreakdown {
        var history = UsageHistory(calendar: .current, asOf: Date())
        history.days[Calendar.current.startOfDay(for: Date())] = UsageDay(totals: UsageTotals(values: values), byModel: models)
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

    func testARangeOfZerosIsEmptyAndATotalWithNothingToSplitItIsTotalsOnly() throws {
        let zeros = try breakdown([.credits: 0, .tokens: 0])
        XCTAssertTrue(zeros.isEmpty)
        XCTAssertFalse(zeros.isTotalsOnly)

        let spendOnly = try breakdown([.spend: 0, .byokSpend: 0])
        XCTAssertFalse(spendOnly.isEmpty, "a zero charge does not rule out free model requests")
        XCTAssertTrue(spendOnly.isTotalsOnly)
        XCTAssertEqual(spendOnly.figures, ["$0"])

        let totals = try breakdown([.credits: 0, .tokens: 766_600_000])
        XCTAssertFalse(totals.isEmpty, "tokens without a charge are still usage")
        XCTAssertTrue(totals.isTotalsOnly)

        let split = try breakdown([.tokens: 100, .inputTokens: 40, .outputTokens: 60])
        XCTAssertFalse(split.isTotalsOnly)

        let modelled = try breakdown([.tokens: 100], models: ["a": UsageTotals(values: [.tokens: 100])])
        XCTAssertFalse(modelled.isTotalsOnly)
    }
}
