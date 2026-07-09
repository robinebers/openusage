import Foundation

/// The single place a number becomes display text. Every surface — popover rows, the menu-bar strip,
/// and hover details — formats through here, so a value can never read one way in the tray and another
/// in the popover, and there is exactly one definition of "compact" (12.9K / 3.4M / 1.2B).
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
            // Percent is a bounded 0...100 domain, so clamp defensively: a bad sample (a provider
            // reporting a negative or >100 utilization) can never print "-5%" or "105%" on any
            // surface that formats through here. Over-limit is conveyed by the meter's spent state
            // and color (see `WidgetData.meterState`), not by an out-of-range headline number.
            return "\(Int(ProviderParse.clampPercent(value).rounded()))%"
        case .dollars:
            // Tray and row abbreviate four figures and up ("$1.2M", "$2.1K") so neither carries
            // "$2,059.07"; the full form (tooltips/headlines) always keeps grouped cents.
            if abs(value) >= 1000, style != .full {
                return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            switch style {
            case .tray:
                // Shortest below $1k: whole dollars ("$130").
                return "$" + value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            case .row, .full:
                // Full cents below $1k; the row's token-count neighbor stays readable.
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

    /// Dollars per million tokens for legends and tooltips — dollar formatting plus a fixed `/MTok`
    /// suffix so those one-line surfaces never drift.
    static func costPerMtok(_ value: Double, style: Style) -> String {
        number(value, kind: .dollars, style: style) + "/MTok"
    }

    /// The Total Spend ring's two-line center: a short primary on top and a quiet unit underneath so
    /// Cost/MTok doesn't cram `/MTok` into the hole. Shared by the live card and the share PNG.
    struct TotalSpendRingCenter: Equatable {
        let primary: String
        let unit: String
    }

    static func totalSpendRingCenter(_ value: Double, metric: TotalSpendMetric) -> TotalSpendRingCenter {
        switch metric {
        case .cost:
            // Keep the `$` — unit line still says "dollars" for clarity in the hole.
            return TotalSpendRingCenter(primary: number(value, kind: .dollars, style: .tray), unit: "dollars")
        case .tokens:
            return tokenRingCenter(value)
        case .costPerMtok:
            // `$1.37` with two decimals under 1k; abbreviated above. Unit line is `MTok`.
            return TotalSpendRingCenter(primary: costPerMtokRingPrimary(value), unit: "MTok")
        }
    }

    /// Dollar-rate figure for the Cost/MTok hole — `$` plus two decimals under 1k, abbreviated above.
    private static func costPerMtokRingPrimary(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        }
        return Formatters.currency(value, fractionDigits: 2)
    }

    /// Token totals put the magnitude word on the second line (`461.8` / `million`) so the hole
    /// stays short even when the total runs past a billion.
    private static func tokenRingCenter(_ value: Double) -> TotalSpendRingCenter {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            let scaled = value / 1_000_000_000
            return TotalSpendRingCenter(
                primary: scaled.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                unit: "billion"
            )
        }
        if magnitude >= 1_000_000 {
            let scaled = value / 1_000_000
            return TotalSpendRingCenter(
                primary: scaled.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                unit: "million"
            )
        }
        if magnitude >= 1_000 {
            let scaled = value / 1_000
            return TotalSpendRingCenter(
                primary: scaled.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                unit: "thousand"
            )
        }
        return TotalSpendRingCenter(
            primary: value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
            unit: "tokens"
        )
    }
}
