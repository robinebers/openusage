import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The name leads with the optional plan badge beside it; the provider mark sits at the trailing
/// edge. Callers supply an optional `warning` — the latest refresh error, rendered as a small amber
/// triangle beside the name whose hover tooltip carries the message (e.g. "Not logged in. Run `codex`
/// to authenticate."). The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
struct ProviderSectionHeader: View {
    let provider: Provider
    var plan: String?
    var warning: String?
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    /// A muted "Outdated" hint shown only when the displayed snapshot has aged past its freshness window
    /// (dashboard only; `nil` in the reorder preview, which never surfaces staleness). Its tooltip carries
    /// the precise age.
    var staleness: StalenessHint?

    /// Header type and icon track the density setting like the rows do, so Compact shrinks the
    /// whole section anatomy — not just the rows under it.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode

    init(provider: Provider, plan: String? = nil, warning: String? = nil, refreshing: Bool = false, staleness: StalenessHint? = nil) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
    }

    var body: some View {
        HStack(spacing: 5) {
            // A grip leading the name marks the header line as draggable to reorder providers. The
            // whole line still carries the gesture; this is only the visual affordance. The trailing
            // gap keeps it from crowding the provider name beside it.
            DragHandleGrip()
                .padding(.trailing, 4)
            // Baseline-aligned pair: the plan badge (and stale tag) are smaller type and sit on the
            // name's text baseline, so the words line up along the bottom rather than floating centered.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Name + plan keep their width and stay on one line; under width pressure (a long plan
                // name like "Super Grok Heavy") the lower-priority stale tag truncates first instead of
                // wrapping the name to a second line.
                Text(provider.displayName)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let plan {
                    ProviderPlanBadge(plan: plan)
                        .layoutPriority(1)
                }
                // Tertiary, below the plan in hierarchy: outdated content, not something the user acts on.
                // Short by design ("Outdated") so it never pushes the plan name onto a second line — the
                // precise age rides in the hover tooltip. Hidden while a refresh is in flight: the spinner
                // already says "working on it".
                if let staleness, !refreshing {
                    Text(staleness.label)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .hoverTooltip(staleness.tooltip)
                }
            }
            if refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            } else if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
            Spacer(minLength: 8)
            // Match the menu-bar strip glyph: a near-zero inset lets the mark fill its box so the
            // header logo reads at the same scale as the tray, instead of floating small inside the
            // default list-context padding.
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
        }
        // Shave the left inset so the leading grip sits a touch closer to the card's edge.
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        // Plain text — no pill/capsule — for a cleaner header. Secondary (not tertiary): the plan
        // name is information the user reads, and tertiary on glass is reserved for inactive
        // content. The smaller point size alone keeps it subordinate to metric values.
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}

/// The 2×3 dot-grid grip that leads the dashboard provider name. Kept quiet (tertiary) so it reads
/// as an affordance hinting the header line can be dragged to reorder providers, not as a control
/// competing with the name beside it.
struct DragHandleGrip: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3) { _ in
                HStack(spacing: 2) {
                    dot
                    dot
                }
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var dot: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: 1.75, height: 1.75)
    }
}
