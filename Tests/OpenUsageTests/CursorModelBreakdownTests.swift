import XCTest
@testable import OpenUsage

// MARK: - Per-model aggregation

final class CursorModelBreakdownTests: XCTestCase {
    /// Pricing variants that share a `family_id` (gpt-5.5 + gpt-5.5-fast) collapse into one family row,
    /// summing tokens and imputed cost across both; the family's display name comes from the manifest.
    func testCollapsesVariantsIntoOneFamilyRow() {
        let rows = [
            makeRow(model: "gpt-5.5", cost: 40.00, tokens: 10_000),
            makeRow(model: "gpt-5.5-fast", cost: 26.00, tokens: 5_000),
            makeRow(model: "composer-1", cost: 5.00, tokens: 1_000)
        ]

        let entries = CursorModelBreakdown.aggregate(rows: rows)

        XCTAssertEqual(entries.map(\.name), ["GPT-5.5", "Composer 1"], "spend-sorted, variants merged")
        let gpt = entries[0]
        XCTAssertEqual(gpt.costDollars, 66.00, accuracy: 1e-9, "40 + 26 merged")
        XCTAssertEqual(gpt.tokens, 15_000, "10k + 5k merged")
        XCTAssertFalse(gpt.isUnpriced)
    }

    /// Sort order is spend descending, then tokens, then name.
    func testSortsBySpendDescending() {
        let rows = [
            makeRow(model: "composer-1", cost: 5.00, tokens: 100),
            makeRow(model: "gpt-5.5", cost: 66.00, tokens: 100),
            makeRow(model: "auto", cost: 15.00, tokens: 100)
        ]
        XCTAssertEqual(CursorModelBreakdown.aggregate(rows: rows).map(\.name), ["GPT-5.5", "Auto", "Composer 1"])
    }

    /// An unknown model has no family, so it keys by its raw id, is flagged unpriced, and still appears
    /// (its usage is real even though its cost is unknown — never silently dropped).
    func testUnknownModelIsKeptAndFlaggedUnpriced() {
        let rows = [
            makeRow(model: "gpt-5.5", cost: 66.00, tokens: 100),
            makeRow(model: "totally-unknown-model-xyz", cost: 0, tokens: 4_000)
        ]
        let entries = CursorModelBreakdown.aggregate(rows: rows)

        let unknown = try! XCTUnwrap(entries.first { $0.name == "totally-unknown-model-xyz" })
        XCTAssertTrue(unknown.isUnpriced)
        XCTAssertEqual(unknown.tokens, 4_000)
        XCTAssertEqual(unknown.costDollars, 0, accuracy: 1e-9)
    }

    /// A row with no measured usage (zero tokens, zero cost) is idle, not a model worth listing.
    func testSkipsZeroUsageRows() {
        let rows = [
            makeRow(model: "gpt-5.5", cost: 0, tokens: 0),
            makeRow(model: "composer-1", cost: 5.00, tokens: 100)
        ]
        XCTAssertEqual(CursorModelBreakdown.aggregate(rows: rows).map(\.name), ["Composer 1"])
    }

    /// Per-family dollars are summed raw, then snapped to whole cents once, so many rows can't drift sub-cent.
    func testSnapsFamilyCostToCents() {
        let rows = [
            makeRow(model: "gpt-5.5", cost: 1.005, tokens: 1),
            makeRow(model: "gpt-5.5", cost: 1.004, tokens: 1)
        ]
        let cost = try! XCTUnwrap(CursorModelBreakdown.aggregate(rows: rows).first?.costDollars)
        XCTAssertEqual(cost, 2.01, accuracy: 1e-9)
    }

    func testEmptyRowsProduceNoEntries() {
        XCTAssertTrue(CursorModelBreakdown.aggregate(rows: []).isEmpty)
    }

    // MARK: - "Other" low-spend bucket

    /// Low-spend models collapse into one summed "Other" row, pinned last; the majors stay. Values are
    /// chosen far from the threshold so the test holds regardless of the exact cutoff (3% / 5%).
    func testFoldsLowSpendTailIntoOther() {
        // total = $100. Two majors (60%, 34%) clear any small cutoff; four models at 1–2% fall below.
        let rows = [
            makeRow(model: "gpt-5.5", cost: 60, tokens: 600),
            makeRow(model: "gpt-5", cost: 34, tokens: 340),
            makeRow(model: "composer-1", cost: 2, tokens: 20),
            makeRow(model: "composer-2", cost: 2, tokens: 20),
            makeRow(model: "auto", cost: 1, tokens: 10),
            makeRow(model: "claude-opus-4-8", cost: 1, tokens: 10)
        ]
        let entries = CursorModelBreakdown.aggregate(rows: rows)

        XCTAssertEqual(entries.map(\.name), ["GPT-5.5", "GPT-5", "Other"])
        let other = entries.last!
        XCTAssertEqual(other.costDollars, 6, accuracy: 1e-9, "2 + 2 + 1 + 1")
        XCTAssertEqual(other.tokens, 60, "20 + 20 + 10 + 10")
        XCTAssertFalse(other.isUnpriced)
        // "Other" lists the folded families (spend-sorted) as its breakdown.
        XCTAssertEqual(other.variants.map(\.name), ["Composer 1", "Composer 2", "Auto", "Claude 4.8 Opus"])
    }

    /// A single sub-threshold model is shown as-is — an "Other" standing in for one model is pointless.
    func testSingleTailModelIsNotBucketed() {
        // composer-1 at 2% is the lone sub-threshold model at either cutoff, so nothing folds.
        let rows = [
            makeRow(model: "gpt-5.5", cost: 60, tokens: 600),
            makeRow(model: "gpt-5", cost: 38, tokens: 380),
            makeRow(model: "composer-1", cost: 2, tokens: 20)
        ]
        XCTAssertEqual(CursorModelBreakdown.aggregate(rows: rows).map(\.name), ["GPT-5.5", "GPT-5", "Composer 1"])
    }

    /// A family's spend split across pricing variants surfaces as a per-variant breakdown (spend-sorted).
    func testEntryCarriesPerVariantBreakdown() {
        let rows = [
            makeRow(model: "gpt-5.5", cost: 40, tokens: 400),
            makeRow(model: "gpt-5.5-fast", cost: 26, tokens: 260)
        ]
        let entries = CursorModelBreakdown.aggregate(rows: rows)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "GPT-5.5")
        XCTAssertEqual(entries[0].variants.map(\.name), ["gpt-5.5", "gpt-5.5-fast"])
        let topVariantCost = try! XCTUnwrap(entries[0].variants.first?.costDollars)
        XCTAssertEqual(topVariantCost, 40, accuracy: 1e-9)
    }

    /// Unpriced models ($0, below any threshold) are never folded — they stay listed so the unknown-model
    /// indicator survives.
    func testUnpricedModelsAreNotFoldedIntoOther() {
        let rows = [
            makeRow(model: "gpt-5.5", cost: 66, tokens: 660),
            makeRow(model: "totally-unknown-a", cost: 0, tokens: 100),
            makeRow(model: "totally-unknown-b", cost: 0, tokens: 50)
        ]
        let entries = CursorModelBreakdown.aggregate(rows: rows)

        XCTAssertFalse(entries.contains { $0.name == "Other" })
        XCTAssertEqual(entries.filter(\.isUnpriced).map(\.name), ["totally-unknown-a", "totally-unknown-b"])
    }

    // MARK: - Mapper line shape

    func testAppendModelLeaderboardEmitsModelsLine() {
        var lines: [MetricLine] = []
        CursorUsageMapper.appendModelLeaderboard(
            rows: [makeRow(model: "gpt-5.5", cost: 66.00, tokens: 100)],
            to: &lines
        )

        guard case .modelBreakdown(let label, let models, let note) = lines.first(where: { $0.label == "Models" }) else {
            return XCTFail("expected a Models leaderboard line")
        }
        XCTAssertEqual(label, "Models")
        XCTAssertEqual(note, "From your Cursor usage history")
        XCTAssertEqual(models.first?.name, "GPT-5.5")
    }

    func testAppendModelLeaderboardAppendsNothingWhenEmpty() {
        var lines: [MetricLine] = []
        CursorUsageMapper.appendModelLeaderboard(rows: [], to: &lines)
        XCTAssertNil(lines.first(where: { $0.label == "Models" }))
    }

    private func makeRow(model: String, cost: Double, tokens: Int) -> CursorUsageCSVRow {
        CursorUsageCSVRow(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            model: model,
            maxMode: false,
            tokens: CursorTokenUsage(inputCacheWrite: 0, inputNoCacheWrite: tokens, cacheRead: 0, output: 0),
            imputedCostDollars: cost
        )
    }
}
