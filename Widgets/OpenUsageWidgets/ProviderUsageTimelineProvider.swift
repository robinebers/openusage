import AppIntents
import Foundation
import WidgetKit

struct ProviderUsageEntry: TimelineEntry {
    let date: Date
    let state: WidgetDisplayState
    let providerID: String?

    static let placeholder = ProviderUsageEntry(
        date: .now,
        state: .provider(.placeholder, isStale: false),
        providerID: "claude"
    )
}

struct ProviderUsageTimelineProvider: AppIntentTimelineProvider {
    // WidgetKit schedules background updates within a limited daily budget. Thirty minutes avoids
    // declaring healthy host data outdated merely because a five-minute host reload was coalesced.
    private let staleInterval: TimeInterval = 30 * 60
    private let fallbackInterval: TimeInterval = 30 * 60
    private let minimumTimelineSpacing: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> ProviderUsageEntry {
        .placeholder
    }

    func snapshot(
        for configuration: ProviderWidgetConfiguration,
        in context: Context
    ) async -> ProviderUsageEntry {
        if context.isPreview { return .placeholder }
        return entry(for: configuration, at: .now)
    }

    func timeline(
        for configuration: ProviderWidgetConfiguration,
        in context: Context
    ) async -> Timeline<ProviderUsageEntry> {
        let now = Date()
        let current = entry(for: configuration, at: now)
        var entries = [current]

        if case .provider(let provider, isStale: false) = current.state,
           let refreshedAt = provider.refreshedAt {
            let staleAt = max(
                refreshedAt.addingTimeInterval(staleInterval),
                now.addingTimeInterval(minimumTimelineSpacing)
            )
            entries.append(ProviderUsageEntry(
                date: staleAt,
                state: .provider(provider, isStale: true),
                providerID: provider.id
            ))
        }

        return Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(fallbackInterval))
        )
    }

    private func entry(
        for configuration: ProviderWidgetConfiguration,
        at date: Date
    ) -> ProviderUsageEntry {
        let result = WidgetBridgeReader.load()
        let selectedID = configuration.provider?.id
            ?? result.document?.providers.first(where: \.isEnabled)?.id
            ?? WidgetProviderCatalog.all.first?.id

        guard let selectedID else {
            return ProviderUsageEntry(date: date, state: .missingData, providerID: nil)
        }

        switch result.status {
        case .missing:
            return ProviderUsageEntry(date: date, state: .missingData, providerID: selectedID)
        case .corrupt:
            return ProviderUsageEntry(date: date, state: .corruptData, providerID: selectedID)
        case .unsupported:
            return ProviderUsageEntry(date: date, state: .unsupportedData, providerID: selectedID)
        case .loaded:
            guard let provider = result.document?.providers.first(where: { $0.id == selectedID }) else {
                return ProviderUsageEntry(
                    date: date,
                    state: .missingProvider(selectedID),
                    providerID: selectedID
                )
            }
            let stale = provider.refreshedAt.map {
                date.timeIntervalSince($0) >= staleInterval
            } ?? true
            return ProviderUsageEntry(
                date: date,
                state: .provider(provider, isStale: stale),
                providerID: selectedID
            )
        }
    }
}

extension WidgetProviderContent {
    static let placeholder = WidgetProviderContent(
        id: "claude",
        displayName: "Claude",
        isEnabled: true,
        plan: "Pro",
        refreshedAt: .now,
        health: .ready,
        primaryMetrics: [
            WidgetMetricContent(
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
            WidgetMetricContent(
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
