import Foundation
import OpenUsageWidgetSupport

@MainActor
struct WidgetBridgeExporter {
    let layout: LayoutStore
    let dataStore: WidgetDataStore

    func makeDocument(generatedAt: Date = Date()) -> WidgetBridgeDocument {
        WidgetBridgeDocument(
            generatedAt: generatedAt,
            providers: layout.orderedProviders().map { provider in
                let metrics = Self.enabledMetricDescriptors(for: provider.id, layout: layout).map {
                    makeMetric($0, generatedAt: generatedAt)
                }
                let snapshot = dataStore.snapshots[provider.id]
                let health: WidgetProviderHealth = if dataStore.backoffs[provider.id] != nil {
                    .failed
                } else if metrics.contains(where: \.hasData) {
                    .ready
                } else {
                    .noData
                }
                return WidgetProviderRecord(
                    id: provider.id,
                    displayName: provider.fullName,
                    iconID: provider.icon,
                    plan: snapshot?.plan,
                    refreshedAt: snapshot?.refreshedAt,
                    health: health,
                    metrics: metrics
                )
            }
        )
    }

    /// Export and click routing share the account's shown metrics, even before its first refresh.
    static func enabledMetricDescriptors(for providerID: String, layout: LayoutStore) -> [WidgetDescriptor] {
        layout.orderedSupportedMetrics(for: providerID).filter { layout.isMetricEnabled($0.id) }
    }

    private func makeMetric(_ descriptor: WidgetDescriptor, generatedAt: Date) -> WidgetMetricRecord {
        let data = dataStore.data(for: descriptor)
        let kind: WidgetMetricKind = if data.isBounded {
            .progress
        } else if data.values.isEmpty, data.valueTextOverride != nil {
            .status
        } else {
            .value
        }
        let headline = data.isBounded
            ? "\(data.valueText) \(data.displayMode.label.lowercased())"
            : data.unboundedDetail
        let severity = data.isBounded
            ? data.meterState(now: generatedAt).severity
            : data.expirySeverity(now: generatedAt)
        return WidgetMetricRecord(
            id: descriptor.id,
            title: data.title,
            kind: kind,
            headline: headline,
            detail: nil,
            progressFraction: data.isBounded ? data.fraction : nil,
            resetAt: data.isFreshSessionWindow(now: generatedAt) ? nil : data.resetsAt,
            severity: data.hasData ? Self.severity(severity) : .neutral,
            hasData: data.hasData && (!data.showsResetExpiries || data.resetCreditCount > 0)
        )
    }

    private static func severity(_ severity: WidgetData.MeterSeverity?) -> WidgetMetricSeverity {
        switch severity {
        case .normal, nil: .normal
        case .warning: .warning
        case .critical: .critical
        }
    }
}
