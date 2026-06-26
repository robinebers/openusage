import SwiftUI

/// The Models row: a compact, right-aligned list of the top model NAMES (rank-numbered), an at-a-glance
/// indicator of which models you've leaned on. It deliberately shows no dollars or tokens inline — that
/// detail lives in the hover popover (`ModelLeaderboardDetail`), which lists every model with its spend
/// and tokens. Reuses the same hover coordinator (`TrendHoverState`) and dwell/grace timing as the Usage
/// Trend sparkline, so the reveal feels identical and tears down with the menu-bar panel.
struct ModelLeaderboardRow: View {
    let data: WidgetData
    /// The row's models (producer-sorted by spend); held directly so the inline ranks and the popover
    /// read one list.
    private let entries: [ModelUsageEntry]

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var hover = TrendHoverState()

    /// How many model names the inline row shows; the rest are revealed on hover.
    private static let inlineCount = 3

    init(data: WidgetData) {
        self.data = data
        self.entries = data.modelEntries
    }

    private var topEntries: [ModelUsageEntry] { Array(entries.prefix(Self.inlineCount)) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(data.title)
                .font(.system(size: density.supportingPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            names
                // Only the names are hoverable — hovering the title must not reveal the detail.
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
                }
                .popover(isPresented: Binding(get: { hover.isPresented }, set: { hover.isPresented = $0 }),
                         arrowEdge: .top) {
                    ModelLeaderboardDetail(title: data.title, entries: entries, note: data.modelNote) { inside in
                        hover.detailHover(inside)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear { hover.dismiss() }
    }

    /// Top-N model names, each trailed by a small numbered rank badge, right-aligned so the badges line
    /// up in a tidy column. Names print at the row's value color (primary) like every other row's payload;
    /// the badge is a quieter secondary so it reads as rank, not data.
    private var names: some View {
        VStack(alignment: .trailing, spacing: 3) {
            // Index-keyed (rank is unique; two families could share a display name).
            ForEach(Array(topEntries.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 5) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // Unknown-model indicator, right behind the name — same as cursorcat. Shows only when
                    // Cursor hasn't priced the model (cost unknown, not zero). Rare inline, since unpriced
                    // models sort to the bottom; the row's a11y label is custom, so the icon is decorative.
                    if entry.isUnpriced {
                        Image(systemName: "exclamationmark.triangle")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    // SF Symbol numbered badge ("1.circle.fill" … "3.circle.fill") in place of a literal
                    // "(1)"; the row's accessibility label already states the rank, so it's decorative here.
                    Image(systemName: "\(index + 1).circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.system(size: density.supportingPointSize))
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var accessibilityLabel: String {
        let names = topEntries.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: ", ")
        let suffix = entries.count > topEntries.count ? ", and \(entries.count - topEntries.count) more" : ""
        return "\(data.title): \(names)\(suffix)."
    }
}
