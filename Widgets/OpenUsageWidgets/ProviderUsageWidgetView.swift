import OpenUsageWidgetSupport
import SwiftUI
import WidgetKit

struct ProviderUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ProviderUsageEntry

    var body: some View {
        Group {
            switch entry.selection {
            case .provider(let provider):
                if !provider.isEnabled {
                    WidgetMessageView(
                        title: "Provider Disabled",
                        message: "Enable \(provider.displayName) in OpenUsage to show its metrics.",
                        symbol: "slider.horizontal.3"
                    )
                } else if provider.health == .noData || selectedMetrics(for: provider).isEmpty {
                    WidgetMessageView(
                        title: "No Data",
                        message: "Open OpenUsage to refresh \(provider.displayName).",
                        symbol: "chart.bar.xaxis"
                    )
                } else {
                    ProviderContentView(
                        date: entry.date,
                        provider: provider,
                        metrics: selectedMetrics(for: provider),
                        isStale: entry.isStale,
                        family: family
                    )
                }
            case .missingData:
                WidgetMessageView(
                    title: "Open OpenUsage",
                    message: "Launch the app once to make usage available.",
                    symbol: "arrow.up.forward.app"
                )
            case .corruptData:
                WidgetMessageView(
                    title: "Unable to Read Data",
                    message: "Open OpenUsage to refresh the widget.",
                    symbol: "exclamationmark.triangle"
                )
            case .unsupportedData:
                WidgetMessageView(
                    title: "Update Required",
                    message: "Update OpenUsage to refresh this widget.",
                    symbol: "arrow.triangle.2.circlepath"
                )
            case .missingProvider:
                WidgetMessageView(
                    title: "Provider Unavailable",
                    message: "Choose another provider or open OpenUsage.",
                    symbol: "questionmark.app"
                )
            }
        }
        .widgetURL(WidgetHostURL.provider(entry.selection.providerID))
    }

    private func selectedMetrics(for provider: WidgetProviderRecord) -> [WidgetMetricRecord] {
        let primary = provider.primaryMetrics.filter(\.hasData)
        let secondary = provider.secondaryMetrics.filter(\.hasData)

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
    let date: Date
    let provider: WidgetProviderRecord
    let metrics: [WidgetMetricRecord]
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
                    WidgetMetricView(
                        date: date,
                        metric: metric,
                        compact: family != .systemLarge,
                        // A small widget's single column only has room for the leading unit.
                        countdownStyle: family == .systemSmall ? .leadingUnit : .relative
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderWidgetHeader: View {
    let provider: WidgetProviderRecord
    let isStale: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProviderIconView(iconID: provider.iconID ?? provider.id)
                .frame(width: 19, height: 19)

            if compact {
                providerTitle
                Spacer(minLength: 0)
                compactStatus
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    providerTitle

                    detailedStatus
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var providerTitle: some View {
        HStack(spacing: 5) {
            // A small widget's status icon leaves room for only one of the two; the plan gives way.
            Text(provider.displayName)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)
            if let plan = provider.plan, !plan.isEmpty {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var status: (title: LocalizedStringKey, symbol: String, color: Color)? {
        switch (provider.health, isStale) {
        case (.failed, _): ("Refresh Failed", "exclamationmark.circle.fill", .red)
        case (.warning, _): ("Warning", "exclamationmark.triangle.fill", .orange)
        case (_, true): ("Outdated", "clock.badge.exclamationmark", .orange)
        default: nil
        }
    }

    @ViewBuilder
    private var compactStatus: some View {
        if let status {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .accessibilityLabel(Text(status.title))
        }
    }

    @ViewBuilder
    private var detailedStatus: some View {
        if let status {
            Label(status.title, systemImage: status.symbol)
                .foregroundStyle(status.color)
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
    /// The timeline entry's date. WidgetKit can render an entry before that moment arrives.
    let date: Date
    let metric: WidgetMetricRecord
    let compact: Bool
    let countdownStyle: CountdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if compact {
                HStack(spacing: 0) {
                    headline
                    Spacer(minLength: 6)
                    if let resetAt = metric.resetAt {
                        let style = style(to: resetAt)
                        // Live-updating text fills whatever width it is offered and has no usable ideal
                        // width, so hidden static text reserves the widest countdown, the live text is
                        // drawn over it, and the headline scales down instead of the countdown truncating.
                        ZStack {
                            ForEach(countdownTemplates(style, to: resetAt), id: \.self) { template in
                                clockLabel(Text(template)).hidden()
                            }
                        }
                        .fixedSize()
                        .overlay {
                            clockLabel(countdown(style, to: resetAt))
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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
                WidgetProgressBar(fraction: progress, color: severityColor)
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

    private func clockLabel(_ text: Text) -> Text {
        Text("\(Image(systemName: "clock")) \(text)")
    }

    private func countdown(_ style: CountdownStyle, to resetAt: Date) -> Text {
        switch style {
        case .relative:
            Text(resetAt, style: .relative)
        case let style:
            Text(.currentDate, format: style.offsetFormat(to: resetAt))
        }
    }

    /// Within the last hour the relative style adds seconds ("49 min, 26 secs") and gets too wide, so
    /// minutes alone take over one entry early, before the next entry could be drawn inside that hour.
    private func style(to resetAt: Date) -> CountdownStyle {
        let minutesStyleFrom: TimeInterval = 60 * 60 + WidgetTimelineSchedule.entrySpacing
        if countdownStyle == .relative, resetAt.timeIntervalSince(date) < minutesStyleFrom { return .minutes }
        return countdownStyle
    }

    /// The countdown as it reads at this entry and at the next one, digits widened to "8". Hidden copies
    /// reserve that width, so the headline only scales down when the real countdown needs the room.
    private func countdownTemplates(_ style: CountdownStyle, to resetAt: Date) -> [String] {
        [date, date.addingTimeInterval(WidgetTimelineSchedule.entrySpacing)].map {
            style.text(from: $0, to: resetAt).replacing(/\d/, with: "8")
        }
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

private enum CountdownStyle {
    /// SwiftUI's relative date style: "2 hrs, 27 min", "5 days, 3 hrs".
    case relative
    /// "2 hours", "5 days".
    case leadingUnit
    /// "49 minutes".
    case minutes

    func offsetFormat(to resetAt: Date) -> SystemFormatStyle.DateOffset {
        let fields: Set<Date.ComponentsFormatStyle.Field> = self == .minutes ? [.minute] : [.day, .hour, .minute]
        return .offset(to: resetAt, allowedFields: fields, maxFieldCount: 1, sign: .never)
    }

    /// Static text for sizing. SwiftUI's relative style reads like the abbreviated components style
    /// limited to its two leading units.
    func text(from date: Date, to resetAt: Date) -> String {
        guard self == .relative else {
            return String(offsetFormat(to: resetAt).format(date).characters)
        }
        let fields: Set<Date.ComponentsFormatStyle.Field> =
            resetAt.timeIntervalSince(date) >= 24 * 60 * 60 ? [.day, .hour] : [.hour, .minute]
        return Date.ComponentsFormatStyle(style: .abbreviated, fields: fields).format(date..<max(date, resetAt))
    }
}

/// A thin bar whose fill joins the accented group, so tinted widgets keep the fill and the translucent
/// track apart (a `ProgressView` renders both in the same tint).
private struct WidgetProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Capsule()
                .fill(.quaternary)
            ProgressFill(fraction: min(max(fraction, 0), 1))
                .fill(color)
                .widgetAccentable()
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    /// Sized from the laid-out rect rather than a `GeometryReader`, which reports an infinite width when an
    /// `HStack` measures it and turns the fill width into NaN.
    private struct ProgressFill: Shape {
        let fraction: Double

        func path(in rect: CGRect) -> Path {
            Capsule().path(in: CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width * fraction,
                height: rect.height
            ))
        }
    }
}

private struct WidgetMessageView: View {
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
