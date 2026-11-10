import SwiftUI

/// A unified limit's row. Hovering or clicking it lists each account's own reading of the limit, or for Limit
/// Resets each account's own resets, since a reset refills only its own account.
struct DashboardUnifiedRow: View {
    let line: DashboardLine
    let resetClaim: (String) -> ResetClaimService?
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?

    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var hover = HoverPopoverState()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            DashboardMetricRow(
                model: line.data.dashboardRow(now: context.date),
                onToggleMeterStyle: line.data.hasMeterStyleToggle ? onToggleMeterStyle : nil,
                onToggleResetDisplay: onToggleResetDisplay,
                valueTooltip: line.data.meterStyleTooltip,
                resetTooltip: line.data.resetTooltip(now: context.date)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { hover.openDetails() }
        .hoverHighlight(hover.overInline || hover.isPresented)
        .onContinuousHover { phase in
            if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Show each account")
        .motionAwareHoverPopover(
            isPresented: Binding(get: { hover.isPresented }, set: { if !$0 { hover.dismiss() } }),
            reduceAnimations: reduceAnimations
        ) {
            Group {
                if line.data.showsResetExpiries {
                    UnifiedResetsDetail(
                        line: line, resetClaim: resetClaim, showsActions: hover.openedExplicitly,
                        onPinChange: { hover.setPinned($0) }
                    )
                } else {
                    UnifiedLimitDetail(line: line)
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { hover.detailHover(true) } else { hover.detailHover(false) }
            }
        }
        .onDisappear { hover.dismiss() }
    }
}

/// Every account with the limit, each with its own bar, amount and reset. A used-up account stays red.
struct UnifiedLimitDetail: View {
    let line: DashboardLine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: DashboardGrid.columnGap) {
                    Text(line.data.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(line.members.count == 1 ? "1 Account" : "\(line.members.count) Accounts")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, Theme.Spacing.xs)
                ForEach(line.members) { member in
                    DashboardMetricRow(model: row(of: member, now: context.date), account: member.provider)
                }
            }
            .padding(14)
            .frame(width: 310)
        }
    }

    private func row(of member: DashboardLine.Member, now: Date) -> DashboardRowModel {
        var row = member.line.data.dashboardRow(now: now)
        row.label = member.provider.accountName
        return row
    }
}

/// Each account's resets under its name. Using one claims it on that account.
private struct UnifiedResetsDetail: View {
    let line: DashboardLine
    let resetClaim: (String) -> ResetClaimService?
    let showsActions: Bool
    let onPinChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(line.members) { member in
                let service = resetClaim(member.provider.id)
                Text(member.provider.accountName)
                    .font(DashboardGrid.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(member.provider.isNamedByEmail ? .middle : .tail)
                    .concealingAccountName(of: member.provider)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, -6)
                RateLimitResetsDetail(
                    count: member.line.data.resetCreditCount,
                    expiries: member.line.data.expiriesAt,
                    items: service?.items ?? [],
                    showsActions: showsActions,
                    onHoverChange: { _ in },
                    onPinChange: onPinChange,
                    claim: service.map { service in
                        { item, requestID in await service.claim(item, requestID: requestID) }
                    }
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
