import SwiftUI
import WidgetKit

struct ProviderUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ProviderUsageEntry

    var body: some View {
        Group {
            switch entry.state {
            case .provider(let provider, let isStale):
                if !provider.isEnabled {
                    WidgetMessageView(
                        providerID: provider.id,
                        title: "Provider Disabled",
                        message: "Enable \(provider.displayName) in OpenUsage to show its metrics.",
                        symbol: "slider.horizontal.3"
                    )
                } else if provider.health == .noData || selectedMetrics(for: provider).isEmpty {
                    WidgetMessageView(
                        providerID: provider.id,
                        title: "No Data",
                        message: "Open OpenUsage to refresh \(provider.displayName).",
                        symbol: "chart.bar.xaxis"
                    )
                } else {
                    ProviderContentView(
                        provider: provider,
                        metrics: selectedMetrics(for: provider),
                        isStale: isStale,
                        family: family
                    )
                }
            case .missingData:
                WidgetMessageView(
                    providerID: entry.providerID,
                    title: "Open OpenUsage",
                    message: "Launch the app once to make usage available.",
                    symbol: "arrow.up.forward.app"
                )
            case .corruptData:
                WidgetMessageView(
                    providerID: entry.providerID,
                    title: "Unable to Read Data",
                    message: "Open OpenUsage to refresh the widget.",
                    symbol: "exclamationmark.triangle"
                )
            case .unsupportedData:
                WidgetMessageView(
                    providerID: entry.providerID,
                    title: "Update Required",
                    message: "Update OpenUsage to refresh this widget.",
                    symbol: "arrow.triangle.2.circlepath"
                )
            case .missingProvider(let providerID):
                WidgetMessageView(
                    providerID: providerID,
                    title: "Provider Unavailable",
                    message: "Choose another provider or open OpenUsage.",
                    symbol: "questionmark.app"
                )
            }
        }
        .widgetURL(WidgetHostURL.provider(entry.providerID))
    }

    private func selectedMetrics(for provider: WidgetProviderContent) -> [WidgetMetricContent] {
        let primary = provider.primaryMetrics.filter { $0.hasData && $0.kind != .chart }
        let secondary = provider.secondaryMetrics.filter { $0.hasData && $0.kind != .chart }

        switch family {
        case .systemSmall:
            return Array((primary.isEmpty ? secondary : primary).prefix(2))
        case .systemMedium:
            return Array((primary.isEmpty ? secondary : primary).prefix(4))
        case .systemLarge:
            if primary.isEmpty { return Array(secondary.prefix(8)) }
            let selectedPrimary = Array(primary.prefix(6))
            return selectedPrimary + secondary.prefix(8 - selectedPrimary.count)
        default:
            return Array((primary.isEmpty ? secondary : primary).prefix(2))
        }
    }
}

private struct ProviderContentView: View {
    let provider: WidgetProviderContent
    let metrics: [WidgetMetricContent]
    let isStale: Bool
    let family: WidgetFamily

    private var columns: [GridItem] {
        family == .systemSmall
            ? [GridItem(.flexible(), spacing: 8)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 10) {
            ProviderWidgetHeader(
                provider: provider,
                isStale: isStale,
                compact: family != .systemLarge
            )

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(metrics) { metric in
                    WidgetMetricView(metric: metric, compact: family != .systemLarge)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderWidgetHeader: View {
    let provider: WidgetProviderContent
    let isStale: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProviderIconView(providerID: provider.id)
                .frame(width: 19, height: 19)

            if compact {
                HStack(spacing: 5) {
                    Text(provider.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if let plan = provider.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                compactStatus
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(provider.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if let plan = provider.plan, !plan.isEmpty {
                            Text(plan)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    detailedStatus
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var compactStatus: some View {
        if provider.health == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Refresh Failed")
        } else if provider.health == .warning {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Warning")
        } else if isStale {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityLabel("Outdated")
        }
    }

    @ViewBuilder
    private var detailedStatus: some View {
        if provider.health == .failed {
            Label("Refresh Failed", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if provider.health == .warning {
            Label("Warning", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if isStale {
            Label("Outdated", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        } else if let refreshedAt = provider.refreshedAt {
            HStack(spacing: 2) {
                Text("Updated")
                Text(refreshedAt, style: .relative)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct WidgetMetricView: View {
    let metric: WidgetMetricContent
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if compact {
                HStack(spacing: 4) {
                    headline
                    Spacer(minLength: 2)
                    if let resetAt = metric.resetAt {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                            Text(resetAt, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            } else {
                headline
            }

            if metric.kind == .progress, let progress = metric.progressFraction {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(severityColor)
            }

            if !compact, let detail = metric.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !compact, let resetAt = metric.resetAt {
                HStack(spacing: 2) {
                    Text("Resets")
                    Text(resetAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headline: some View {
        Text(metric.headline)
            .font(compact ? .subheadline : .headline)
            .fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private var severityColor: Color {
        switch metric.severity {
        case .critical: .red
        case .warning: .orange
        case .normal: .accentColor
        case .neutral: .secondary
        }
    }
}

private struct WidgetMessageView: View {
    let providerID: String?
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Text("Open OpenUsage")
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }
}

enum WidgetHostURL {
    static func provider(_ providerID: String?) -> URL? {
        guard
            let scheme = Bundle.main.object(
                forInfoDictionaryKey: "OpenUsageURLScheme"
            ) as? String,
            !scheme.isEmpty
        else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "provider"
        if let providerID { components.path = "/\(providerID)" }
        return components.url
    }
}

#Preview("Small", as: .systemSmall) {
    ProviderUsageWidget()
} timeline: {
    ProviderUsageEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    ProviderUsageWidget()
} timeline: {
    ProviderUsageEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    ProviderUsageWidget()
} timeline: {
    ProviderUsageEntry.placeholder
}
