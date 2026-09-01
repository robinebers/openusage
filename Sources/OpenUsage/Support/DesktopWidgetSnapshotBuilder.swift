import Foundation
import OpenUsageWidgetSupport

/// Projects the user's menu-bar pins into the small, presentation-ready contract consumed by the
/// desktop widget. Pins are already an explicit, ordered choice of glanceable metrics, so the widget
/// follows that choice instead of introducing a second customization system.
@MainActor
enum DesktopWidgetSnapshotBuilder {
    static func make(
        layout: LayoutStore,
        dataStore: WidgetDataStore,
        displayName: (Provider) -> String,
        concealsUsage: Bool = false,
        now: Date = Date()
    ) -> DesktopWidgetSnapshot {
        guard !concealsUsage else {
            return DesktopWidgetSnapshot(updatedAt: nil, metrics: [], isRedacted: true)
        }
        let groups = layout.pinnedGroups
        let metrics = groups.flatMap { group in
            group.metrics.map { descriptor in
                makeMetric(
                    providerName: displayName(group.provider),
                    descriptor: descriptor,
                    data: dataStore.data(for: descriptor),
                    now: now
                )
            }
        }
        let updatedAt = groups
            .compactMap { dataStore.snapshots[$0.provider.id]?.refreshedAt }
            .max()
        return DesktopWidgetSnapshot(updatedAt: updatedAt, metrics: metrics)
    }

    static func makeMetric(
        providerName: String,
        descriptor: WidgetDescriptor,
        data: WidgetData,
        now: Date
    ) -> DesktopWidgetMetric {
        let status: DesktopWidgetMetric.Status
        if !data.hasData || !data.isBounded {
            status = .neutral
        } else {
            status = switch data.meterState(now: now).severity {
            case .some(.normal): .normal
            case .some(.warning): .warning
            case .some(.critical): .critical
            case .none: .neutral
            }
        }

        let value = data.hasData
            ? (data.isBounded ? data.boundedHeadline : data.unboundedDetail)
            : WidgetData.noDataHeadline
        let subtitle = data.hasData
            ? (data.isBounded ? data.boundedSubtitle : data.unboundedSubtitle)
            : WidgetData.noDataSubtitle

        return DesktopWidgetMetric(
            id: descriptor.id,
            providerName: providerName,
            title: descriptor.title,
            value: value,
            subtitle: subtitle,
            progress: data.hasData && data.isBounded ? data.fraction : nil,
            status: status
        )
    }
}
