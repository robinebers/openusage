import AppKit

/// Gmail-style UI density for the popover. Two levels: Default breathes; Compact is a real
/// information-dense mode — type steps down one size, rows and sections pull together, and the
/// management rows (Customize / Settings) tighten with them. Padding tweaks alone read as "slightly
/// cramped Default", so Compact changes type and structure, not just whitespace. This enum is the
/// single source for every density-dependent dimension — views read these properties instead of
/// hardcoding sizes, so a third level later is one more case here. The popover width is *not*
/// density-dependent (deliberate: switching density shouldn't move the popover's left edge).
enum DensitySetting: String, Hashable, Sendable, CaseIterable {
    case regular
    case compact

    static let key = "density"

    var label: String {
        switch self {
        case .regular: return "Default"
        case .compact: return "Compact"
        }
    }

    // MARK: - Type (the biggest densitizer at menu-bar sizes)

    /// Metric row label. Default matches the system headline; Compact steps one point down —
    /// semantic `.headline.weight(.regular)` does not match `.headline` on macOS, so the size is
    /// resolved explicitly and weight stays semibold at the call site.
    var labelPointSize: CGFloat {
        let base = NSFont.preferredFont(forTextStyle: .headline).pointSize
        return self == .compact ? base - 1 : base
    }

    /// Under-bar / detail text: one step below the label in both densities so it recedes instead
    /// of reading as a second heavy line.
    var supportingPointSize: CGFloat { self == .compact ? 11 : 12 }

    /// Provider name in the section header — a touch larger than the metric label below it so the
    /// section title reads as the heaviest thing in the group.
    var headerPointSize: CGFloat { self == .compact ? 13 : 14 }

    /// Provider mark in the section header.
    var headerIconSize: CGFloat { self == .compact ? 14 : 16 }

    /// Plan badge beside the provider name — always one step below the supporting text.
    var planBadgePointSize: CGFloat { self == .compact ? 10 : 11 }

    // MARK: - Dimensions (all on the 4pt grid or its 2pt half-steps)

    /// Vertical padding on a bounded (meter) row: 20pt bar-to-bar in Default, 10pt in Compact.
    var barRowPadding: CGFloat { self == .compact ? 5 : 10 }

    /// Capsule meter height — a thin hairline like Claude Code's usage bars (a 10pt bar read as a
    /// chunky slab next to them). Default's bar is one step taller to match its airier rhythm.
    var meterHeight: CGFloat { self == .compact ? 4 : 5 }

    /// Usage Trend sparkline height. Steps down in Compact so the chart row tightens with the rest of
    /// the card instead of standing taller than its neighbors.
    var trendChartHeight: CGFloat { self == .compact ? 14 : 18 }

    /// Vertical padding on a text-only row.
    var textRowPadding: CGFloat { self == .compact ? 4 : 6 }

    /// Top padding for a text-only row sitting directly under another text-only row — the
    /// neighbor-aware rule, active in **both** densities so runs of one-liners (Today / Yesterday /
    /// Last 30 Days) always read as one cluster; Compact pulls them a step harder.
    var condensedTextRowTopPadding: CGFloat { self == .compact ? 1 : 2 }

    /// Spacing inside a bounded row between the label, the meter, and the reading line.
    var rowInnerSpacing: CGFloat { self == .compact ? 3 : 4 }

    /// Spacing between provider sections (dashboard and Customize alike). Compact halves the gap
    /// but stays clearly wider than the in-card rhythm, so groups still read as groups.
    var sectionSpacing: CGFloat { self == .compact ? 8 : 14 }

    /// Gap between a provider header and its card.
    var headerToCardSpacing: CGFloat { self == .compact ? 2 : 4 }

    /// Vertical gutter inside a metric card (keeps the first/last row off the card edge).
    var cardGutter: CGFloat { self == .compact ? 3 : 5 }

    /// Vertical padding on a Customize / Settings control row (toggles, pickers).
    var controlRowPadding: CGFloat { self == .compact ? 6 : 9 }

    /// Top padding above the dashboard list.
    var contentTopPadding: CGFloat { self == .compact ? 10 : 14 }

    /// Estimated Customize control-row height for the pre-measurement height seed
    /// (row content ≈ 24pt + `controlRowPadding` × 2).
    var estimatedMetricRowHeight: CGFloat { self == .compact ? 36 : 42 }

    /// The Customize "Shown on Expand" divider draws smaller than a metric row, while its invisible
    /// reorder frame stays row-sized so the drag threshold keeps matching normal rows.
    var customizeDividerRowHeight: CGFloat { self == .compact ? 24 : 28 }

    /// Gap between cells in the dashboard's expanded-metrics grid (the area that opens below the
    /// caret laying secondary metrics up to three across). Kept tight so two or three narrow cells
    /// still read as one cluster, like the condensed text rows do in the single column above.
    var expandedGridSpacing: CGFloat { self == .compact ? 4 : 6 }
}
