import AppKit
import SwiftUI

/// The row of per-provider quick-link buttons (e.g. "Status", "Console") shown in a provider card's
/// expanded area. Lays out up to three across; extra links wrap to the next row. Each button opens its
/// URL in the default browser. Mirrors the legacy Tauri `provider-card` quick-links row, adapted to the
/// native card's expanded area (issue #596 — "bring back provider buttons").
struct ProviderLinksView: View {
    let links: [ProviderLink]
    /// Matches the metric-row inset so the button row lines up with the rows above/below it. The
    /// expanded-metrics grid passes a tighter value; links keep the full inset since they sit on their
    /// own line, not inside a narrow cell.
    var horizontalInset: CGFloat = 14

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Hard ceiling from #596: never more than three buttons across, regardless of how many links a
    /// provider ships. Fewer links use fewer columns so a lone button isn't boxed into a third of the row.
    private static let maxColumns = 3

    private var columns: [GridItem] {
        let count = min(Self.maxColumns, max(1, links.count))
        return Array(repeating: GridItem(.flexible(), spacing: density.expandedGridSpacing, alignment: .top),
                     count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: density.expandedGridSpacing) {
            ForEach(links, id: \.self) { link in
                linkButton(link)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, density.textRowPadding)
        .padding(.bottom, density.textRowPadding)
    }

    private func linkButton(_ link: ProviderLink) -> some View {
        Button {
            if let url = URL(string: link.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(link.label)
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: density.supportingPointSize - 2))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("\(link.label), opens in browser")
    }
}
