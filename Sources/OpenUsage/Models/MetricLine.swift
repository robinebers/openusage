import Foundation

/// Provider output normalized into a small app-owned vocabulary.
///
/// This mirrors the old JavaScript plugin contract while keeping rendering decisions in Swift.
enum ProgressFormat: Hashable, Sendable, Codable {
    case percent
    case dollars
    case count(suffix: String)

    var metricKind: MetricKind {
        switch self {
        case .percent:
            return .percent
        case .dollars:
            return .dollars
        case .count:
            return .count
        }
    }

    var countSuffix: String? {
        if case .count(let suffix) = self { return suffix }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case suffix
    }

    private enum Kind: String, Codable {
        case percent
        case dollars
        case count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .percent:
            self = .percent
        case .dollars:
            self = .dollars
        case .count:
            self = .count(suffix: try container.decode(String.self, forKey: .suffix))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .percent:
            try container.encode(Kind.percent, forKey: .kind)
        case .dollars:
            try container.encode(Kind.dollars, forKey: .kind)
        case .count(let suffix):
            try container.encode(Kind.count, forKey: .kind)
            try container.encode(suffix, forKey: .suffix)
        }
    }
}

/// One column of a `.chart` line: a day's value, its axis label ("Jun 21"), and the pre-formatted
/// readout shown on hover ("222M tokens"). The producer formats `valueLabel` so the chart stays a dumb
/// renderer of already-priced numbers, the same split the spend tiles use.
struct MetricChartPoint: Hashable, Sendable, Codable {
    var value: Double
    var label: String
    var valueLabel: String?

    /// The hover readout for this day: the producer's pre-formatted label, or a compact token count as a
    /// fallback. One definition so the inline sparkline and the detail popover never format it differently.
    var readout: String {
        valueLabel ?? (MetricFormatter.number(value, kind: .count, style: .row) + " tokens")
    }
}

enum MetricLine: Hashable, Sendable, Codable {
    case text(label: String, value: String, colorHex: String? = nil, subtitle: String? = nil)
    /// A small day-by-day bar chart (the Usage Trend row). Carries the raw per-day points plus an
    /// optional source note; the view formats and draws them. Unbounded, never pinned to the menu bar.
    case chart(label: String, points: [MetricChartPoint], note: String? = nil)
    /// An unbounded row carrying one or more raw numbers (see `MetricValue`) — the preferred shape for
    /// numeric rows. The number is the source of truth; formatting and which value(s) to show happen at
    /// the display edge, so the menu bar never has to re-parse a finished string. `.text` stays only for
    /// genuinely string-valued provider notices exposed through the local API; widgets do not parse it.
    ///
    /// `expiriesAt` carries zero or more future expiry instants the row surfaces in its hover tooltip —
    /// used for the Codex rate-limit-reset-credits row ("2 available", with each credit's expiry listed
    /// on hover). Carried as raw `Date`s (not baked strings) so they count down on the popover's clock
    /// tick and honor the global relative/absolute reset mode, like a bounded row's reset countdown.
    ///
    /// `unknownModels` carries the names of models this period's spend used that the pricing sources
    /// don't know. Their usage is left out of the displayed total, so the row shows a warning triangle
    /// listing them on hover. `modelBreakdown` carries the period-scoped ranked model
    /// list for spend rows; it is internal UI data, not part of the local HTTP API wire shape.
    case values(
        label: String,
        values: [MetricValue],
        colorHex: String? = nil,
        expiriesAt: [Date] = [],
        unknownModels: [String] = [],
        modelBreakdown: ModelUsageBreakdown? = nil
    )
    case progress(
        label: String,
        used: Double,
        limit: Double,
        format: ProgressFormat,
        resetsAt: Date? = nil,
        periodDurationMs: Int? = nil,
        colorHex: String? = nil
    )
    case badge(label: String, text: String, colorHex: String? = nil, subtitle: String? = nil)

    var label: String {
        switch self {
        case .text(let label, _, _, _),
             .progress(let label, _, _, _, _, _, _),
             .values(let label, _, _, _, _, _),
             .badge(let label, _, _, _),
             .chart(let label, _, _):
            return label
        }
    }

    /// The badge label that marks a provider-level error line (produced by `ProviderSnapshot.error`).
    /// Shared so the producer and `isError`'s detection are compile-time coupled and can't drift apart —
    /// a silent drift would let a failed provider's error render as a normal pill and cache stale data.
    static let errorBadgeLabel = "Error"

    var isError: Bool {
        if case .badge(let label, _, _, _) = self {
            return label == Self.errorBadgeLabel
        }
        return false
    }

    /// The shared "no usage data" placeholder badge, shown when a provider returns no metric lines.
    static let noUsageData = MetricLine.badge(label: "Status", text: "No usage data", colorHex: "#A3A3A3")

    /// Append `noUsageData` when nothing was produced, so an empty result reads as a clear status
    /// instead of a blank tile.
    static func appendNoDataIfNeeded(_ lines: inout [MetricLine]) {
        if lines.isEmpty {
            lines.append(.noUsageData)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case label
        case value
        case values
        case used
        case limit
        case format
        case resetsAt
        case expiriesAt
        case unknownModels
        case modelBreakdown
        case periodDurationMs
        case colorHex
        case subtitle
        case text
        case points
        case note
    }

    private enum LineType: String, Codable {
        case text
        case values
        case progress
        case badge
        case chart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decode(String.self, forKey: .label)
        switch try container.decode(LineType.self, forKey: .type) {
        case .text:
            self = .text(
                label: label,
                value: try container.decode(String.self, forKey: .value),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case .values:
            self = .values(
                label: label,
                values: try container.decode([MetricValue].self, forKey: .values),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                expiriesAt: try container.decodeIfPresent([Date].self, forKey: .expiriesAt) ?? [],
                unknownModels: try container.decodeIfPresent([String].self, forKey: .unknownModels) ?? [],
                modelBreakdown: try container.decodeIfPresent(ModelUsageBreakdown.self, forKey: .modelBreakdown)
            )
        case .progress:
            self = .progress(
                label: label,
                used: try container.decode(Double.self, forKey: .used),
                limit: try container.decode(Double.self, forKey: .limit),
                format: try container.decode(ProgressFormat.self, forKey: .format),
                resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
                periodDurationMs: try container.decodeIfPresent(Int.self, forKey: .periodDurationMs),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex)
            )
        case .badge:
            self = .badge(
                label: label,
                text: try container.decode(String.self, forKey: .text),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case .chart:
            self = .chart(
                label: label,
                points: try container.decode([MetricChartPoint].self, forKey: .points),
                note: try container.decodeIfPresent(String.self, forKey: .note)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let label, let value, let colorHex, let subtitle):
            try container.encode(LineType.text, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        case .values(let label, let values, let colorHex, let expiriesAt, let unknownModels, let modelBreakdown):
            try container.encode(LineType.values, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(values, forKey: .values)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            if !expiriesAt.isEmpty { try container.encode(expiriesAt, forKey: .expiriesAt) }
            if !unknownModels.isEmpty { try container.encode(unknownModels, forKey: .unknownModels) }
            try container.encodeIfPresent(modelBreakdown, forKey: .modelBreakdown)
        case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, let colorHex):
            try container.encode(LineType.progress, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
            try container.encode(format, forKey: .format)
            try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
            try container.encodeIfPresent(periodDurationMs, forKey: .periodDurationMs)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
        case .badge(let label, let text, let colorHex, let subtitle):
            try container.encode(LineType.badge, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        case .chart(let label, let points, let note):
            try container.encode(LineType.chart, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(points, forKey: .points)
            try container.encodeIfPresent(note, forKey: .note)
        }
    }
}
