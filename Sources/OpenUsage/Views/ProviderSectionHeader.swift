import SwiftUI

/// Everything a header needs to act as a mini-card control. `nil` on surfaces that never collapse
/// (the reorder preview) and whenever Settings → Appearance → Enable Mini Cards is off, so the
/// header keeps exactly its pre-feature behavior: no hover swap, no click target, no meters.
struct MiniCardHeaderModel {
    /// Whether this provider is currently collapsed.
    var isMinimized: Bool
    /// Which collapsed layout to draw.
    var style: MiniCardStyle
    /// The bars the collapsed header shows, already derived from the card's own rows.
    var meters: [MiniMeter]
    /// Flip this provider's collapsed state. Animated by the header, so the card and the header move
    /// in one transaction.
    var toggle: () -> Void

    init(isMinimized: Bool, style: MiniCardStyle, meters: [MiniMeter], toggle: @escaping () -> Void = {}) {
        self.isMinimized = isMinimized
        self.style = style
        self.meters = meters
        self.toggle = toggle
    }
}

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead, followed by the optional plan badge. Dashboard callers supply a
/// screenshot-copy action, revealed at the trailing edge while the header is hovered. Callers can also
/// supply an optional `warning` — the latest refresh error, rendered as a small amber
/// triangle beside the name whose hover tooltip carries the message (e.g. "Not logged in. Run `codex`
/// to authenticate."). The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
///
/// With `miniCard` supplied the header doubles as the provider's collapse control. Hovering the mark
/// or the name (the two things the click acts on, and nothing else in the row) cross-fades the mark
/// into a chevron pointing down while the card is open and right while it is collapsed. There is no
/// persistent chevron: the affordance appears under the pointer and nowhere else, so an idle header
/// looks exactly as it always has.
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
    /// Dashboard-only screenshot action. The reorder preview omits it, while Customize uses its own
    /// row type and is unaffected by this header.
    var onCopyScreenshot: (() -> Bool)?
    /// Mini-card state and control. `nil` disables the whole affordance.
    var miniCard: MiniCardHeaderModel?

    /// Header type and icon track the density setting like the rows do, so Compact shrinks the
    /// whole section anatomy — not just the rows under it.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    /// Drops the repeated agent prefix from a multi-account provider's name (Settings → Appearance).
    @AppStorage(HideAgentNameSetting.key) private var hideAgentName = HideAgentNameSetting.fallback
    /// Masks any email left in the name (Settings → Privacy → Hide Emails).
    @AppStorage(HideEmailsSetting.key) private var hideEmails = HideEmailsSetting.fallback
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode
    @State private var isHovered = false
    /// Tracked separately per control so moving the pointer from the mark to the name (or back) can't
    /// strand the swap: one leaving and the other entering are independent events.
    @State private var isMarkHovered = false
    @State private var isNameHovered = false

    init(
        provider: Provider,
        plan: String? = nil,
        warning: String? = nil,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onCopyScreenshot: (() -> Bool)? = nil,
        miniCard: MiniCardHeaderModel? = nil
    ) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
        self.onCopyScreenshot = onCopyScreenshot
        self.miniCard = miniCard
    }

    private var isMinimized: Bool { miniCard?.isMinimized ?? false }

    /// The chevron replaces the mark only while the pointer is on one of the two things that respond
    /// to a click.
    private var showsChevron: Bool { miniCard != nil && (isMarkHovered || isNameHovered) }

    /// Single Row buys its pill's width from the plan badge, the one header element that is purely
    /// descriptive. The name truncates from there; the warning, spinner, and staleness tag all stay.
    private var hidesPlanBadge: Bool {
        isMinimized && miniCard?.style == .singleRow
    }

    private var showsPill: Bool {
        guard let miniCard else { return false }
        return miniCard.isMinimized && miniCard.style == .singleRow && !miniCard.meters.isEmpty
    }

    private var showsMeterLine: Bool {
        guard let miniCard else { return false }
        return miniCard.isMinimized && miniCard.style == .detailed && !miniCard.meters.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerLine
            if showsMeterLine, let miniCard {
                // Aligned to where the provider name starts, so the meters read as a second line of
                // the header rather than the first row of a card.
                MiniMeterLine(meters: miniCard.meters, leadingInset: density.headerIconSize + 5)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var headerLine: some View {
        HStack(spacing: 5) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational until mini
            // cards give it an action.
            providerMark
            // Baseline-aligned pair: the plan badge (and stale tag) are smaller type and sit on the
            // name's text baseline, so the words line up along the bottom rather than floating centered.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Name + plan keep their width and stay on one line; under width pressure (a long plan
                // name like "Super Grok Heavy") the lower-priority stale tag truncates first instead of
                // wrapping the name to a second line.
                providerName
                    .layoutPriority(1)
                if let plan, !hidesPlanBadge {
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
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityLabel("Refreshing")
            } else if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
            Spacer(minLength: 8)
            if showsPill, let miniCard {
                // Scales out of the trailing edge the collapsing card shrinks toward, so the pill
                // reads as what the card became rather than a new element arriving.
                MiniMeterPill(meters: miniCard.meters)
                    .transition(.scale(scale: 0.72, anchor: .trailing).combined(with: .opacity))
            }
            // A mini card has no rows on screen to frame, and the pill already owns the trailing edge.
            if let onCopyScreenshot, !isMinimized {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(provider.visibleName(hidingEmails: hideEmails)) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot
                )
            }
        }
    }

    private var markIcon: some View {
        ProviderIcon(source: provider.icon, inset: 0.04)
            .frame(width: density.headerIconSize, height: density.headerIconSize)
            .partyPulse(partyMode)
    }

    /// The mark, or the chevron it becomes under the pointer. Both live in the same box and swap by
    /// cross-fade plus a small scale, so the header never reflows and nothing jumps.
    @ViewBuilder
    private var providerMark: some View {
        if let miniCard {
            Button {
                toggle(miniCard)
            } label: {
                ZStack {
                    markIcon
                        .opacity(showsChevron ? 0 : 1)
                        .scaleEffect(showsChevron ? 0.55 : 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: density.headerIconSize - 4, weight: .semibold))
                        .foregroundStyle(.primary)
                        .rotationEffect(.degrees(miniCard.isMinimized ? -90 : 0))
                        .opacity(showsChevron ? 1 : 0)
                        .scaleEffect(showsChevron ? 1 : 0.55)
                }
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .contentShape(Rectangle())
                .animation(Motion.modeSwitch, value: showsChevron)
                .animation(Motion.spring, value: miniCard.isMinimized)
            }
            .buttonStyle(.plain)
            .onHover { isMarkHovered = $0 }
            .accessibilityLabel(toggleAccessibilityLabel(minimized: miniCard.isMinimized))
        } else {
            markIcon
        }
    }

    private var nameText: some View {
        Text(provider.headerName(hidingAgentName: hideAgentName, hidingEmails: hideEmails))
            .font(.system(size: density.headerPointSize, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var providerName: some View {
        if let miniCard {
            Button {
                toggle(miniCard)
            } label: {
                nameText.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isNameHovered = $0 }
            .accessibilityLabel(toggleAccessibilityLabel(minimized: miniCard.isMinimized))
        } else {
            nameText
        }
    }

    /// One transaction for the whole section: the card's collapse, the header's meters, and the
    /// chevron's rotation all ride the same spring.
    private func toggle(_ miniCard: MiniCardHeaderModel) {
        withAnimation(Motion.spring) {
            miniCard.toggle()
        }
    }

    private func toggleAccessibilityLabel(minimized: Bool) -> String {
        let name = provider.visibleName(hidingEmails: hideEmails)
        return minimized ? "Expand \(name)" : "Collapse \(name)"
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
