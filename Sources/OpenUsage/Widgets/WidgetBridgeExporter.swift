import Foundation
import OpenUsageWidgetSupport

@MainActor
struct WidgetBridgeExporter {
    let registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let enablement: ProviderEnablementStore

    func makeDocument(generatedAt: Date = Date()) -> WidgetBridgeDocument {
        let orderedProviders = layout.customizeProviderRows.map(\.provider)
        return WidgetBridgeDocument(
            generatedAt: generatedAt,
            providers: orderedProviders.map { provider in
                makeProvider(provider, generatedAt: generatedAt)
            }
        )
    }

    private func makeProvider(_ provider: Provider, generatedAt: Date) -> WidgetProviderRecord {
        let descriptors = layout.orderedSupportedMetrics(for: provider.id).filter {
            layout.isMetricEnabled($0.id) && !dataStore.data(for: $0).isChart
        }
        let primary = descriptors.filter { !layout.isMetricExpanded($0.id) }
        let secondary = descriptors.filter { layout.isMetricExpanded($0.id) }
        let snapshot = dataStore.snapshots[provider.id]
        let records = descriptors.reduce(into: [String: WidgetMetricRecord]()) { result, descriptor in
            result[descriptor.id] = makeMetric(descriptor, generatedAt: generatedAt)
        }
        let hasData = records.values.contains(where: \.hasData)

        let health: WidgetProviderHealth
        if dataStore.errorMessage(for: provider.id) != nil {
            health = .failed
        } else if dataStore.warningMessage(for: provider.id) != nil {
            health = .warning
        } else if snapshot != nil, hasData {
            health = .ready
        } else {
            health = .noData
        }

        return WidgetProviderRecord(
            id: provider.id,
            displayName: provider.displayName,
            isEnabled: enablement.isEnabled(provider.id),
            plan: snapshot?.plan,
            refreshedAt: snapshot?.refreshedAt,
            health: health,
            primaryMetrics: primary.compactMap { records[$0.id] },
            secondaryMetrics: secondary.compactMap { records[$0.id] }
        )
    }

    private func makeMetric(_ descriptor: WidgetDescriptor, generatedAt: Date) -> WidgetMetricRecord {
        let data = dataStore.data(for: descriptor)
        let kind: WidgetMetricKind = if data.isBounded {
            .progress
        } else if data.selectedValues.isEmpty, data.valueTextOverride != nil {
            .status
        } else {
            .value
        }
        let detail: String? = if data.isBounded, data.isFreshSessionWindow(now: generatedAt) {
            "Not started"
        } else if data.isBounded, data.resetsAt != nil {
            // The extension renders the raw date with SwiftUI's dynamic date styles. Baking a countdown
            // here would make the shared payload stale every minute and require needless host reloads.
            nil
        } else if data.isBounded {
            data.boundedTrailingText(now: generatedAt)
        } else {
            data.unboundedDetail
        }

        return WidgetMetricRecord(
            id: descriptor.id,
            title: data.title,
            kind: kind,
            headline: data.headline,
            detail: detail == data.headline ? nil : detail,
            progressFraction: data.isBounded ? data.fraction : nil,
            resetAt: data.resetsAt,
            severity: severity(for: data, now: generatedAt),
            hasData: data.hasData
        )
    }

    private func severity(for data: WidgetData, now: Date) -> WidgetMetricSeverity {
        guard data.hasData else { return .neutral }
        let severity = data.isBounded
            ? data.meterState(now: now).severity
            : data.expirySeverity(now: now)
        return switch severity {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        case nil: .normal
        }
    }
}
