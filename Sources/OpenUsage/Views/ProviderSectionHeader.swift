import SwiftUI

/// Shared provider section header used by the dashboard, Customize, and lifted reorder previews.
/// The name leads with the optional plan badge beside it; the provider mark sits at the trailing
/// edge. Callers supply only an optional accessory after the mark (drag grip) and an optional
/// `warning` — the latest refresh error, rendered as a small amber triangle beside the name whose
/// hover tooltip carries the message (e.g. "Not logged in. Run `codex` to authenticate.").
struct ProviderSectionHeader<Trailing: View>: View {
    let provider: Provider
    var plan: String?
    var warning: String?
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    private let trailing: Trailing

    /// Header type and icon track the density setting like the rows do, so Compact shrinks the
    /// whole section anatomy — not just the rows under it.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    init(provider: Provider, plan: String? = nil, warning: String? = nil, refreshing: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 5) {
            // Baseline-aligned pair: the plan badge is smaller type, so centering it against
            // the name leaves it floating high — text sits together only on a shared baseline.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(provider.displayName)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                if let plan {
                    ProviderPlanBadge(plan: plan)
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
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

extension ProviderSectionHeader where Trailing == EmptyView {
    init(provider: Provider, plan: String? = nil, warning: String? = nil, refreshing: Bool = false) {
        self.init(provider: provider, plan: plan, warning: warning, refreshing: refreshing) { EmptyView() }
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
