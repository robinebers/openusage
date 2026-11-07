import XCTest
@testable import OpenUsage

final class DitherPatternTests: XCTestCase {
    func testBarsStaySolidUntilTheSettingSaysOtherwise() {
        XCTAssertEqual(LevelFillSetting.current, .solid)
        XCTAssertEqual(LevelFillSetting.allCases.map(\.label), ["Solid", "Dithered"])
    }

    func testCellsAreWholeDevicePixelsNearOneAndAHalfPoints() {
        XCTAssertEqual(DitherPattern.cellSize(scale: 2), 1.5)
        XCTAssertEqual(DitherPattern.cellSize(scale: 1), 2)
    }

    func testTheFillEndsOnAWholeCellAndNeverShorterThanTheSolidBar() {
        XCTAssertEqual(DitherPattern.fillWidth(0, in: 180, cell: 1.5), 0)
        XCTAssertEqual(DitherPattern.fillWidth(0.5, in: 181, cell: 1.5), 90)
        XCTAssertEqual(DitherPattern.fillWidth(0.001, in: 180, cell: 1.5), 4.5, "three cells cover the solid bar's 4-point minimum")
        XCTAssertEqual(DitherPattern.fillWidth(1.4, in: 180, cell: 1.5), 180)
    }

    func testTheFillStartsSolidAndThinsToACheckerboardAtItsEdge() {
        let columns = 100
        XCTAssertEqual(DitherPattern.density(column: 0, columns: columns), 1)
        XCTAssertEqual(DitherPattern.density(column: 39, columns: columns), 1)
        XCTAssertEqual(DitherPattern.density(column: columns - 1, columns: columns), DitherPattern.edgeDensity)
        XCTAssertEqual(DitherPattern.density(column: 0, columns: 1), 1)

        func onCells(_ range: Range<Int>) -> Int {
            range.reduce(0) { count, column in
                count + (0..<4).filter { DitherPattern.isOn(column: column, row: $0, columns: columns) }.count
            }
        }
        XCTAssertEqual(onCells(0..<4), 16, "every cell of a solid block is on")
        XCTAssertEqual(onCells(96..<100), 8, "half the cells of a block at the edge are on")
    }
}
