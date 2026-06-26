import SwiftUI

/// The detail-on-demand popover for a Models row: every model the inline row summarizes, listed with
/// its window-total spend and tokens (spend-sorted, like the inline ranks). Mirrors `UsageTrendDetail` —
/// a fixed-width panel with a header, a body, and the source note — and reports hover so the trigger
/// keeps it open while the cursor travels from the inline names into the list.
///
/// The body sizes to its content and only starts scrolling once it would exceed `maxListHeight`. That
/// switch keys off the *measured* content height (not a row count), so it can't silently clip when row
/// metrics change; when scrolling, the rows gain a trailing gutter so the scroller never sits on the values.
struct ModelLeaderboardDetail: View {
    let title: String
    let entries: [ModelUsageEntry]
    let note: String?
    /// Reports whether the cursor is inside the popover, so the trigger keeps it open while the user
    /// moves from the inline row into the list, and closes it once they leave both.
    var onHoverChange: (Bool) -> Void

    @State private var contentHeight: CGFloat = 0

    private static let width: CGFloat = 250
    private static let maxListHeight: CGFloat = 280
    /// Trailing room for the overlay scroller so it clears the values; applied only while scrolling, so a
    /// short non-scrolling list stays symmetric.
    private static let scrollGutter: CGFloat = 10

    /// Scroll only once the content would overflow the cap — measured, not guessed from the row count.
    private var scrolls: Bool { contentHeight > Self.maxListHeight }
    private var gutter: CGFloat { scrolls ? Self.scrollGutter : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            list
            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, gutter)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("Last 30 Days")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, gutter)
    }

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                // Index-keyed: the list is a fixed snapshot, and two families could in principle share a
                // display name, so position is the stable identity (not the name).
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    row(entry)
                }
            }
            .padding(.trailing, gutter)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ModelListHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(maxHeight: Self.maxListHeight)
        // Size to content until it exceeds the cap, then scroll. The flip keys off the measured height
        // above, so a short list never reserves empty space and a long one scrolls instead of clipping.
        .fixedSize(horizontal: false, vertical: !scrolls)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ModelListHeightKey.self) { contentHeight = $0 }
    }

    private func row(_ entry: ModelUsageEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if entry.isUnpriced {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No model pricing available")
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(costLabel(entry))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(tokenLabel(entry))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // Hover breakdown, like cursorcat: a family's per-variant cost split, or — for "Other" — the
        // folded families it stands for. Each line shows the exact (un-abbreviated) dollars.
        .hoverTooltip(variantTooltip(entry))
        .accessibilityElement(children: .combine)
    }

    /// The hover breakdown for a row: one `name — $exact` line per variant/member, spend-sorted. `nil`
    /// when there's nothing to break down (so the row gets no tooltip).
    private func variantTooltip(_ entry: ModelUsageEntry) -> String? {
        guard !entry.variants.isEmpty else { return nil }
        return entry.variants
            .map { variant in
                let cost = variant.isUnpriced
                    ? WidgetData.noDataHeadline
                    : MetricFormatter.number(variant.costDollars, kind: .dollars, style: .full)
                return "\(variant.name) — \(cost)"
            }
            .joined(separator: "\n")
    }

    /// An unpriced model's cost is unknown (not zero), so it reads an em dash rather than "$0.00".
    private func costLabel(_ entry: ModelUsageEntry) -> String {
        entry.isUnpriced ? WidgetData.noDataHeadline : MetricFormatter.number(entry.costDollars, kind: .dollars, style: .row)
    }

    private func tokenLabel(_ entry: ModelUsageEntry) -> String {
        MetricFormatter.number(Double(entry.tokens), kind: .count, style: .row) + " tokens"
    }
}

/// Measures the leaderboard's intrinsic content height so the popover can size to content up to a cap.
private struct ModelListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
