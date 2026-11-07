import SwiftUI

/// A limit's level as pixels: a grid of cells over a faint base, each cell on or off by an ordered
/// (Bayer) threshold, so the fill starts solid and thins to a checkerboard at its edge.
struct DitheredLevel: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let cell = DitherPattern.cellSize(scale: displayScale)
            let width = DitherPattern.fillWidth(fill, in: proxy.size.width, cell: cell)
            let color = Theme.severityColor(severity)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.meterTrack)
                if width > 0 {
                    Rectangle().fill(color.opacity(DitherPattern.baseOpacity)).frame(width: width)
                    DitherShape(width: width, cell: cell).fill(color)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The cells that are on across a fill `width` wide, each `cell` square, over the whole rect's height.
struct DitherShape: Shape {
    var width: CGFloat
    let cell: CGFloat

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let columns = Int((width / cell).rounded())
        let rows = Int((rect.height / cell).rounded(.up))
        for column in 0..<columns {
            for row in 0..<rows where DitherPattern.isOn(column: column, row: row, columns: columns) {
                path.addRect(CGRect(x: rect.minX + CGFloat(column) * cell, y: rect.minY + CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        return path
    }
}

enum DitherPattern {
    /// Bayer 4×4 thresholds: neighbouring cells turn on in a spread-out order, never in rows.
    static let bayer: [[Int]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
    /// The share of the fill that stays solid before it starts to thin.
    static let solidShare = 0.4
    /// How many cells in one are on at the fill's edge.
    static let edgeDensity = 0.5
    /// The off cells still show the fill's colour this faintly, so the bar's length reads at a glance.
    static let baseOpacity = 0.35
    private static let cellPoints: CGFloat = 1.5
    private static let shortestFill: CGFloat = 4

    /// About 1.5 points, rounded to whole device pixels so every cell draws crisp.
    static func cellSize(scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        return max(1, (cellPoints * scale).rounded()) / scale
    }

    /// The fill's width in whole cells, so its edge is a pixel step and never a slice of a cell. A fill
    /// above zero is never shorter than the solid bar's shortest fill.
    static func fillWidth(_ fill: Double, in width: CGFloat, cell: CGFloat) -> CGFloat {
        guard fill > 0, width > 0 else { return 0 }
        let wanted = width * min(fill, 1)
        let columns = max((wanted / cell).rounded(.down), (shortestFill / cell).rounded(.up))
        return min(columns * cell, width)
    }

    /// The share of cells that are on in `column` of `columns`: every one through the solid share, then
    /// fewer and fewer down to the edge density.
    static func density(column: Int, columns: Int) -> Double {
        guard columns > 1 else { return 1 }
        let position = Double(column) / Double(columns - 1)
        guard position > solidShare else { return 1 }
        return 1 - (position - solidShare) / (1 - solidShare) * (1 - edgeDensity)
    }

    static func isOn(column: Int, row: Int, columns: Int) -> Bool {
        let threshold = (Double(bayer[row % 4][column % 4]) + 0.5) / 16
        return density(column: column, columns: columns) > threshold
    }
}
