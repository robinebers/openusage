import Foundation

/// One bar in a collapsed provider header. A miniature of the metric row's own meter: same fraction,
/// same severity color, same percentage the row's headline reads, so a mini card can never disagree
/// with the card it replaces.
///
/// Only bounded rows with real data can be miniaturized: a bar needs a limit to fill against, and a
/// gray no-data track carries nothing at this size. Sparkline rows (Usage Trend) are skipped
/// too, because they have no single value to reduce to one number.
struct MiniMeter: Identifiable, Hashable {
    /// The source metric's descriptor id, so the header's bars keep stable SwiftUI identity across
    /// refreshes instead of remapping by position.
    let id: String
    /// The metric's name ("Session", "Weekly"). Shown by the Detailed style, dropped by Single Row.
    let title: String
    /// Fill 0...1, taken straight from the row so the Used/Left toggle moves both together.
    let fraction: Double
    /// Bar color band, or `nil` for a track with no verdict. Mirrors `WidgetData.MeterState.severity`.
    let severity: WidgetData.MeterSeverity?
    /// The whole-percent reading beside the bar ("57%"), rounded the same way the fill is.
    let percentText: String
    /// True when this is the last reading the provider managed to report rather than a current one.
    /// Drawn faded, so a bar that is standing in for fresh data never reads as fresh.
    let isOutdated: Bool

    /// Most bars a mini card shows. Three is what fits the 320pt popover in either style with the
    /// provider name still readable; a provider with more bounded metrics shows its first three.
    static let limit = 3

    /// A miniature of one metric row, or `nil` when the row has no meter worth shrinking.
    init?(id: String, data: WidgetData, now: Date = Date()) {
        guard !data.isChart, data.hasData, data.isBounded else { return nil }
        self.id = id
        self.title = data.title
        self.fraction = data.fraction
        self.severity = data.meterState(now: now).severity
        self.percentText = "\(Int((data.fraction * 100).rounded()))%"
        self.isOutdated = data.isOutdated
    }

    /// The bars for one provider's mini card: its rows in card order, meterless ones dropped, capped
    /// at `limit`. Callers pass the rows the open card shows above the fold, so the mini card
    /// summarizes exactly what collapsing hid, never a metric the user tucked behind the caret.
    static func meters(from rows: [(id: String, data: WidgetData)], now: Date = Date()) -> [MiniMeter] {
        Array(rows.compactMap { MiniMeter(id: $0.id, data: $0.data, now: now) }.prefix(limit))
    }
}
