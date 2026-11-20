import Foundation

enum MetricFormatter {
    enum Style {
        case tray
        case row
    }

    private static let locale = Locale(identifier: "en_US")
    /// Rupees group in lakhs and crores: ₹1,00,000.
    private static let indianLocale = Locale(identifier: "en_IN")

    static func number(
        _ value: Double, kind: MetricKind, style: Style, currencyCode: String? = nil, in display: DisplayCurrency? = nil
    ) -> String {
        switch kind {
        case .percent:
            return "\(Int(ProviderParse.clampPercent(value).rounded()))%"
        case .dollars:
            var value = value
            var code = currencyCode ?? "USD"
            if let display, let converted = display.convert(value, from: code) {
                value = converted
                code = display.code
            }
            switch style {
            case .tray:
                let symbol = Locale(identifier: "en_US@currency=\(code)").currencySymbol ?? code
                if abs(value) >= 1000 {
                    return symbol + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
                }
                let digits = value != 0 && abs(value) < 1 ? 2 : 0
                return symbol + value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
            case .row:
                let whole = (value * 100).rounded().truncatingRemainder(dividingBy: 100) == 0
                return value.formatted(.currency(code: code).precision(.fractionLength(whole ? 0 : 2)).locale(code == "INR" ? indianLocale : locale))
            }
        case .count:
            if abs(value) >= 1000 {
                return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        }
    }

    static func string(for value: MetricValue, style: Style, in display: DisplayCurrency? = nil) -> String {
        let text = number(value.number, kind: value.kind, style: style, currencyCode: value.currencyCode, in: display)
        guard let label = value.label, !label.isEmpty else { return text }
        return "\(text) \(label)"
    }
}
