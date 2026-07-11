import SwiftUI

/// An off-screen, branded PNG of one provider's usage, rendered for the right-click "Share Screenshot"
/// action. It is a static snapshot — no drag grips, spinners, staleness tags, or refresh warnings — that
/// mirrors what the provider's card currently shows in the popover (respecting whether the caret is
/// expanded), drawn at the popover's own scale and rasterized at ×4 for a crisp, large share image.
///
/// The layout is intentionally not a fixed canvas: the card height grows with its rows, so a collapsed
/// provider exports a short card and an expanded one a tall one, with little wasted whitespace. The view
/// takes already-resolved `[WidgetData]` (not a store), so it has no environment dependency and renders
/// the same way in the app and in tests. It paints an opaque `Theme.traySurface` background (an
/// `ImageRenderer` has no window backdrop) and forces the appearance via `.environment(\.colorScheme, …)`
/// so a Light-mode user gets a light card even when the OS is in dark mode.
struct ShareCardView: View {
    let provider: Provider
    var plan: String?
    let rows: [WidgetData]
    let appearance: ColorScheme
    /// Index in `rows` where the On Demand rows begin (the Always Visible count), so the
    /// neighbor-aware condensing treats the expand caret as a hard boundary the way the live dashboard
    /// does. `nil` when the provider is collapsed (no expanded section).
    var expandBoundaryIndex: Int? = nil

    /// Authored card width in points. The renderer multiplies this by `ShareCardRenderer.scale` for the
    /// PNG's pixel width; the height is whatever the rows add up to (flexible).
    static let width: CGFloat = 360

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            metricsCard
        }
    }

    // MARK: - Header

    /// Provider mark + name (+ optional plan), leading — logo, then name, then plan — at the popover's
    /// type scale so it sits in proportion to the rows. Static: no drag grip, spinner, staleness tag, or
    /// warning triangle.
    private var headerRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: 22, height: 22)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Body

    /// The provider's visible metric rows in the shared card surface, reusing `WidgetRowView` so the
    /// exported card matches the live dashboard exactly. Toggles are nil (static render). An empty
    /// provider falls back to a quiet placeholder so the card never renders blank.
    @ViewBuilder
    private var metricsCard: some View {
        if rows.isEmpty {
            DashboardMetricCard {
                Text("No metrics to show")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        } else {
            DashboardMetricCard {
                let condensed = Self.condensedTextRowIndices(rows, boundary: expandBoundaryIndex)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, data in
                    WidgetRowView(data: data, condensedTop: condensed.contains(index))
                }
            }
        }
    }

    /// Flat indices of text-only rows that condense under another text-only row — the neighbor-aware rule
    /// the live dashboard applies (shared via `WidgetData.condensedTextRowOffsets`), so a run of one-liners
    /// (Today / Yesterday / Last 30 Days) clusters in the export the same way it does in the popover. The
    /// expand caret is a hard boundary: each segment (always-shown, then expanded) is scanned separately,
    /// never across, and its segment-local offsets are mapped back to flat `rows` indices.
    static func condensedTextRowIndices(_ rows: [WidgetData], boundary: Int? = nil) -> Set<Int> {
        let edges = boundary.map { [0, $0, rows.count] } ?? [0, rows.count]
        var indices = Set<Int>()
        for (lower, upper) in zip(edges, edges.dropFirst()) {
            let offsets = WidgetData.condensedTextRowOffsets(in: Array(rows[lower..<upper]))
            indices.formUnion(offsets.map { lower + $0 })
        }
        return indices
    }

}
