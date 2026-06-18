import Foundation

/// The single place a number becomes display text. Every surface — popover rows, the menu-bar strip,
/// the gallery — formats through here, so a value can never read one way in the tray and another in
/// the popover, and there is exactly one definition of "compact" (12.9K / 3.4M / 1.2B).
///
/// This replaces the scattered number→string logic that used to live in `WidgetData.format`, the
/// menu bar's `compactValue`, and the providers' own `formatTokens` / credit-label builders.
enum MetricFormatter {
    /// Three surfaces, three needs:
    /// - `.tray` — the menu-bar strip: shortest. Whole dollars under $1,000, abbreviated above; counts abbreviated.
    /// - `.row` — the popover row: abbreviated like the tray, but money keeps cents / two decimals ("$2.06K", "$40.76").
    /// - `.full` — tooltips and bounded headlines: every digit, grouped ("$2,059.07", "56,904,995").
    enum Style {
        case tray
        case row
        case full
    }

    /// Pinned to en_US so USD-denominated values render identically regardless of system locale, which
    /// matches the menu bar's long-standing behavior.
    private static let locale = Locale(identifier: "en_US")

    /// A bare number in the given kind and style (no unit label).
    static func number(_ value: Double, kind: MetricKind, style: Style) -> String {
        switch kind {
        case .percent:
            return "\(Int(value.rounded()))%"
        case .dollars:
            switch style {
            case .tray:
                // Shortest: whole dollars under $1k ("$130"), abbreviated above ("$1.2M").
                if abs(value) >= 1000 {
                    return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
                }
                return "$" + value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            case .row:
                // Abbreviate four figures and up ("$2.1K") so the row can't carry "$2,059.07" beside a
                // token count — one decimal, matching the token counts next to it; full cents below $1k.
                if abs(value) >= 1000 {
                    return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
                }
                return Formatters.currency(value, fractionDigits: 2)
            case .full:
                return Formatters.currency(value, fractionDigits: 2)
            }
        case .count:
            // Tray and row abbreviate at the thousands (token counts run into the billions); the full
            // form keeps every digit for the tooltip. Below 1,000 keeps up to one decimal either way, so
            // a fractional balance (e.g. 820.6) survives.
            if style != .full, abs(value) >= 1000 {
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
