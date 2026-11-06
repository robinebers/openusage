import Foundation

/// How the menu-bar item renders usage:
/// - `text`: Provider icon + values (one segment per item)
/// - `bars`: Compact horizontal bars (up to four bounded metric bars)
/// - `gauge`: Dual-arc monochrome ring gauge (top 1/3 for 5h, bottom 2/3 for 7d)
/// - `colorGauge`: Dual-arc colored ring gauge with pace guideline marks
enum MenuBarStyle: String, Hashable, Sendable, CaseIterable {
    case text
    case bars
    case gauge
    case colorGauge

    var label: String {
        switch self {
        case .text: return "Text"
        case .bars: return "Bars"
        case .gauge: return "Gauge"
        case .colorGauge: return "Color Gauge"
        }
    }
}
