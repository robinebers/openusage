import Foundation
#if canImport(OpenUsageWidgetSupport)
import OpenUsageWidgetSupport
#endif
import OSLog
import SwiftUI
import WidgetKit

private struct DesktopUsageEntry: TimelineEntry {
    var date: Date
    var snapshot: DesktopWidgetSnapshot
    var appIsReachable: Bool

    static let placeholder = DesktopUsageEntry(
        date: Date(),
        snapshot: DesktopWidgetSnapshot(
            updatedAt: Date(),
            metrics: [
                DesktopWidgetMetric(
                    id: "claude.session",
                    providerName: "Claude",
                    title: "Session",
                    value: "82% left",
                    subtitle: "Resets in 3h 12m",
                    progress: 0.82,
                    status: .normal
                ),
                DesktopWidgetMetric(
                    id: "codex.weekly",
                    providerName: "Codex",
                    title: "Weekly",
                    value: "41% left",
                    subtitle: "Resets in 4d 8h",
                    progress: 0.41,
                    status: .warning
                ),
                DesktopWidgetMetric(
                    id: "cursor.auto",
                    providerName: "Cursor",
                    title: "Auto",
                    value: "73% left",
                    subtitle: nil,
                    progress: 0.73,
                    status: .normal
                ),
                DesktopWidgetMetric(
                    id: "openrouter.credits",
                    providerName: "OpenRouter",
                    title: "Credits",
                    value: "$18.42 left",
                    subtitle: nil,
                    progress: nil,
                    status: .neutral
                ),
            ]
        ),
        appIsReachable: true
    )
}

/// WidgetKit's callback isn't annotated Sendable, while URLSession's completion is. This tiny wrapper
/// carries the system callback across that boundary; it is invoked exactly once by the loader.
private final class CompletionBox<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func callAsFunction(_ value: Value) {
        callback(value)
    }
}

private struct DesktopWidgetSnapshotLoader: Sendable {
    private static let endpoint = URL(string: "http://127.0.0.1:6736/v1/widget")!
    private static let logger = Logger(subsystem: "com.robinebers.openusage.widget", category: "timeline")

    func load(completion: @escaping @Sendable (DesktopWidgetSnapshot?) -> Void) {
        var request = URLRequest(url: Self.endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                Self.logger.error("snapshot request failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Self.logger.error("snapshot response invalid (status=\(status, privacy: .public))")
                completion(nil)
                return
            }
            do {
                completion(try JSONDecoder().decode(DesktopWidgetSnapshot.self, from: data))
            } catch {
                Self.logger.error("snapshot decode failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
            }
        }.resume()
    }
}

private struct DesktopUsageTimelineProvider: TimelineProvider {
    private let loader = DesktopWidgetSnapshotLoader()

    func placeholder(in context: Context) -> DesktopUsageEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (DesktopUsageEntry) -> Void) {
        guard !context.isPreview else {
            completion(.placeholder)
            return
        }
        loadEntry(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DesktopUsageEntry>) -> Void) {
        let box = CompletionBox(completion)
        loadEntry { entry in
            // The containing app also invalidates this timeline whenever pins or their values change.
            // This periodic request is a recovery path for app launches and temporarily missed reloads.
            let refreshAt = Date().addingTimeInterval(5 * 60)
            box(Timeline(entries: [entry], policy: .after(refreshAt)))
        }
    }

    private func loadEntry(completion: @escaping (DesktopUsageEntry) -> Void) {
        let box = CompletionBox(completion)
        loader.load { snapshot in
            box(
                DesktopUsageEntry(
                    date: Date(),
                    snapshot: snapshot ?? .empty,
                    appIsReachable: snapshot != nil
                )
            )
        }
    }
}

private struct DesktopUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DesktopUsageEntry

    private var rowLimit: Int {
        switch family {
        case .systemSmall: 2
        case .systemMedium: 4
        case .systemLarge: 8
        case .systemExtraLarge: 12
        default: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            header
            if entry.snapshot.isRedacted {
                privacyState
            } else if entry.snapshot.metrics.isEmpty {
                emptyState
            } else {
                metricRows
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(DesktopWidgetDeepLink.dashboardURL(bundleIdentifier: Bundle.main.bundleIdentifier))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            Text("OpenUsage")
                .font(.headline)
            Spacer(minLength: 4)
            if let updatedAt = entry.snapshot.updatedAt {
                Text(updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Spacer(minLength: 0)
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: entry.appIsReachable ? "pin.slash" : "arrow.clockwise")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.appIsReachable ? "No Pinned Metrics" : "Open OpenUsage")
                .font(.subheadline.weight(.semibold))
            Text(
                entry.appIsReachable
                    ? "Pin a metric in Customize to show it here."
                    : "Launch the menu-bar app to update this widget."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
    }

    private var privacyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 0)
            Image(systemName: "eye.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Usage Hidden")
                .font(.subheadline.weight(.semibold))
            Text("Screen sharing is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var metricRows: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 9) {
            ForEach(Array(entry.snapshot.metrics.prefix(rowLimit))) { metric in
                DesktopWidgetMetricRow(metric: metric, compact: family == .systemSmall)
            }
            if entry.snapshot.metrics.count > rowLimit, family != .systemSmall {
                Text("+\(entry.snapshot.metrics.count - rowLimit) more pinned")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DesktopWidgetMetricRow: View {
    let metric: DesktopWidgetMetric
    let compact: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if compact {
                    Text("\(metric.providerName) · \(metric.title)")
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(metric.providerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(metric.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(metric.value)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .privacySensitive()
            }
            if let progress = metric.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(metric.status.tint)
                    .accessibilityLabel("\(metric.providerName), \(metric.title)")
                    .accessibilityValue(metric.value)
            } else if !compact, let subtitle = metric.subtitle {
                HStack {
                    Spacer()
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private extension DesktopWidgetMetric.Status {
    var tint: Color {
        switch self {
        case .neutral: .secondary
        case .normal: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

@main
struct OpenUsageDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: DesktopUsageWidgetKind.value,
            provider: DesktopUsageTimelineProvider()
        ) { entry in
            DesktopUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage Overview")
        .description("See your pinned AI usage metrics at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
