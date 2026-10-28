import Foundation

enum MetricFormatter {
    enum Style {
        case tray
        case row
    }

    private static let locale = Locale(identifier: "en_US")

    static func number(_ value: Double, kind: MetricKind, style: Style) -> String {
        switch kind {
        case .percent:
            return "\(Int(ProviderParse.clampPercent(value).rounded()))%"
        case .dollars:
            if abs(value) >= 1000 {
                return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            switch style {
            case .tray:
                return "$" + value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            case .row:
                let whole = (value * 100).rounded().truncatingRemainder(dividingBy: 100) == 0
                return value.formatted(.currency(code: "USD").precision(.fractionLength(whole ? 0 : 2)).locale(locale))
            }
        case .count:
            if abs(value) >= 1000 {
                return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        }
    }

    static func string(for value: MetricValue, style: Style) -> String {
        let text = number(value.number, kind: value.kind, style: style)
        guard let label = value.label, !label.isEmpty else { return text }
        return "\(text) \(label)"
    }
}
