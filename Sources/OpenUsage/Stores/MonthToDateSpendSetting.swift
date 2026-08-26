import Foundation

/// Master visibility switch for the optional per-provider month-to-date spend rows.
/// The rows are registered for every local spend provider but are not in `DefaultLayout.metricIDs`,
/// so the setting is off on a fresh install and after Reset All Settings.
enum MonthToDateSpendSetting {
    static let key = "showMonthToDateSpend"

    static func metricIDs(in registry: WidgetRegistry) -> [String] {
        registry.descriptors
            .filter { $0.isSpendTile && $0.id.hasSuffix(".monthToDate") }
            .map(\.id)
    }
}
