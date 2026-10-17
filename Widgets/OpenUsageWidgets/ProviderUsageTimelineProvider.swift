import AppIntents
import Foundation
import OpenUsageWidgetSupport
import WidgetKit

struct ProviderUsageEntry: TimelineEntry {
    let date: Date
    let selection: WidgetProviderSelection.Entry
    let isStale: Bool

    static let placeholder = ProviderUsageEntry(
        date: .now,
        selection: .provider(.placeholder),
        isStale: false
    )
}

struct ProviderUsageTimelineProvider: AppIntentTimelineProvider {
    // WidgetKit schedules background updates within a limited daily budget. Thirty minutes avoids
    // declaring healthy host data outdated merely because a five-minute host reload was coalesced.
    private let staleInterval: TimeInterval = 30 * 60
    private let fallbackInterval = WidgetTimelineSchedule.entrySpacing
    private let minimumTimelineSpacing: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> ProviderUsageEntry {
        .placeholder
    }

    func snapshot(
        for configuration: ProviderWidgetConfiguration,
        in context: Context
    ) async -> ProviderUsageEntry {
        if context.isPreview { return .placeholder }
        return entry(for: selection(for: configuration), at: .now)
    }

    func timeline(
        for configuration: ProviderWidgetConfiguration,
        in context: Context
    ) async -> Timeline<ProviderUsageEntry> {
        let now = Date()
        let selection = selection(for: configuration)
        var dates = WidgetTimelineSchedule.entryDates(from: now)

        if case .provider(let provider) = selection, let refreshedAt = provider.refreshedAt {
            dates.append(max(
                refreshedAt.addingTimeInterval(staleInterval),
                now.addingTimeInterval(minimumTimelineSpacing)
            ))
        }

        return Timeline(
            entries: dates.sorted().map { entry(for: selection, at: $0) },
            policy: .after(now.addingTimeInterval(fallbackInterval))
        )
    }

    private func selection(for configuration: ProviderWidgetConfiguration) -> WidgetProviderSelection.Entry {
        let result = WidgetBridgeReader.load()
        return WidgetProviderSelection.entry(
            configuredID: configuration.provider?.id,
            bridgeStatus: result.status,
            in: result.document?.providers ?? []
        )
    }

    private func entry(for selection: WidgetProviderSelection.Entry, at date: Date) -> ProviderUsageEntry {
        let isStale: Bool = if case .provider(let provider) = selection {
            provider.refreshedAt.map {
                date.timeIntervalSince($0) >= staleInterval
            } ?? true
        } else {
            false
        }
        return ProviderUsageEntry(date: date, selection: selection, isStale: isStale)
    }
}

extension WidgetProviderRecord {
    static let placeholder = WidgetProviderRecord(
        id: "claude",
        displayName: "Claude",
        iconID: "claude",
        isEnabled: true,
        plan: "Pro",
        refreshedAt: .now,
        health: .ready,
        primaryMetrics: [
            WidgetMetricRecord(
                id: "session",
                title: "Session",
                kind: .progress,
                headline: "38% Used",
                detail: nil,
                progressFraction: 0.38,
                resetAt: .now.addingTimeInterval(3_600),
                severity: .normal,
                hasData: true
            ),
            WidgetMetricRecord(
                id: "weekly",
                title: "Weekly",
                kind: .progress,
                headline: "64% Used",
                detail: nil,
                progressFraction: 0.64,
                resetAt: .now.addingTimeInterval(86_400),
                severity: .warning,
                hasData: true
            ),
        ],
        secondaryMetrics: []
    )
}
