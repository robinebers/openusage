import SwiftUI
import XCTest
@testable import OpenUsage

/// A card's bars run from the label to the figure, whatever the reset shows (issue #1715).
@MainActor
final class DashboardBarWidthTests: XCTestCase {
    private let width = PanelMetrics.width - 2 * PanelMetrics.margin - 2 * DashboardGrid.cardPadding
    private let inset: CGFloat = 12 // Keeps InkMap's reference column clear of the label.

    private func card(resets: [String?], fill: Double = 1, paceMark: Double? = nil) throws -> InkMap {
        let rows = resets.map { reset in
            DashboardRowModel(label: "Weekly", mark: .bar(fill: fill, severity: .normal, value: "3%", reset: reset), paceMark: paceMark)
        }
        let card = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { DashboardMetricRow(model: rows[$0]) }
        }
        .sharingDashboardColumns()
        .padding(.leading, inset)
        .environment(\.drawsLevelsAsShapes, true)
        return try InkMap(rendering: card, width: width + inset, scale: 2)
    }

    /// Inked columns along the middle of row `row`, as runs of points.
    private func runs(_ map: InkMap, row: Int) -> [Range<CGFloat>] {
        let y = (CGFloat(row) + 0.5) * DashboardGrid.rowHeight
        var runs: [Range<CGFloat>] = []
        var start: CGFloat?
        for x in stride(from: CGFloat(0), through: width + inset, by: 0.5) {
            let inked = x < width + inset && map.count(x: x..<x + 0.5, y: y - 1..<y + 1) > 0
            if inked, start == nil { start = x }
            if !inked, let begun = start { runs.append(begun..<x); start = nil }
        }
        return runs
    }

    /// The bar is the one long run; the figure starts at the next.
    private func barAndFigure(_ map: InkMap, row: Int) throws -> (bar: Range<CGFloat>, figure: CGFloat) {
        let runs = runs(map, row: row)
        let bar = try XCTUnwrap(runs.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }, "row \(row) drew nothing")
        let figure = try XCTUnwrap(runs.first { $0.lowerBound > bar.upperBound }, "row \(row) has no figure")
        return (bar, figure.lowerBound)
    }

    func testABarReachesItsFigureWithCountdownsAndClockTimes() throws {
        for resets in [["3d 4h", "23h 59m"], ["Wed 10:58 PM", "Thu 9:05 AM"], [nil, "3d 4h"]] {
            let map = try card(resets: resets)
            for row in resets.indices {
                let (bar, figure) = try barAndFigure(map, row: row)
                // Only the column gap and the figure's side bearing lie between the bar and a short figure.
                XCTAssertLessThanOrEqual(figure - bar.upperBound, DashboardGrid.columnGap + 3, "\(resets) row \(row)")
                XCTAssertGreaterThan(bar.upperBound - bar.lowerBound, 0.4 * width, "\(resets) row \(row)")
            }
            XCTAssertEqual(try barAndFigure(map, row: 0).bar, try barAndFigure(map, row: 1).bar, "\(resets): a card's bars line up")
        }
    }

    func testThePaceMarkSitsAtItsShareOfTheWiderTrack() throws {
        let track = try barAndFigure(try card(resets: ["3d 4h"]), row: 0).bar
        let marked = try card(resets: ["3d 4h"], fill: 0, paceMark: 0.5)
        let mark = try XCTUnwrap(runs(marked, row: 0).first { $0.lowerBound > track.lowerBound + 1 && $0.upperBound < track.upperBound })
        let center = (mark.lowerBound + mark.upperBound) / 2
        XCTAssertEqual(center, (track.lowerBound + track.upperBound) / 2, accuracy: 1.5)
    }
}
