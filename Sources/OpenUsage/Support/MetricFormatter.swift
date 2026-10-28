import Foundation

/// The single place a number becomes display text. Every surface — popover rows, the menu-bar strip,
/// and hover details — formats through here, so a value can never read one way in the tray and another
/// in the popover, and there is exactly one definition of "compact" (12.9K / 3.4M / 1.2B).
enum MetricFormatter {
    /// Two surfaces, two needs:
    /// - `.tray` — the menu-bar strip: shortest. Whole dollars under $1,000, abbreviated above; counts abbreviated.
    /// - `.row` — the popover row: abbreviated like the tray, and money keeps its cents unless it's whole
    ///   dollars ("$2.1K", "$40.76", "$500").
    enum Style {
        case tray
        case row
    }

    /// Pinned to en_US so USD-denominated values render identically regardless of system locale, which
    /// matches the menu bar's long-standing behavior.
    private static let locale = Locale(identifier: "en_US")

    /// A bare number in the given kind and style (no unit label).
    static func number(_ value: Double, kind: MetricKind, style: Style) -> String {
        switch kind {
        case .percent:
            // Percent is a bounded 0...100 domain, so clamp defensively: a bad sample (a provider
            // reporting a negative or >100 utilization) can never print "-5%" or "105%" on any
            // surface that formats through here. Over-limit is conveyed by the meter's spent state
            // and color (see `WidgetData.meterState`), not by an out-of-range number.
            return "\(Int(ProviderParse.clampPercent(value).rounded()))%"
        case .dollars:
            // Four figures and up abbreviate ("$1.2M", "$2.1K") so neither surface carries "$2,059.07".
            if abs(value) >= 1000 {
                return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            switch style {
            case .tray:
                // Shortest below $1k: whole dollars ("$130").
                return "$" + value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            case .row:
                // Cents below $1k, dropped when they're zero so a whole amount reads "$500".
                let whole = (value * 100).rounded().truncatingRemainder(dividingBy: 100) == 0
                return value.formatted(.currency(code: "USD").precision(.fractionLength(whole ? 0 : 2)).locale(locale))
            }
        case .count:
            // Abbreviated at the thousands (token counts run into the billions). Below 1,000 keeps up to
            // one decimal, so a fractional balance (e.g. 820.6) survives.
            if abs(value) >= 1000 {
                return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        }
    }

    /// A value with its unit label appended, e.g. "772 credits". Token, dollar, and percent values
    /// carry no label and render bare ("56.9M", "$4.08", "95%") — those rows show no unit, by design.
    static func string(for value: MetricValue, style: Style) -> String {
        let text = number(value.number, kind: value.kind, style: style)
        guard let label = value.label, !label.isEmpty else { return text }
        return "\(text) \(label)"
    }
}
