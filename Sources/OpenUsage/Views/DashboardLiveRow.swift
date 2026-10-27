import SwiftUI

/// A metric row on the live dashboard. Rows with a clock re-render every 30 s so their reset stays live;
/// a click on the value flips every row between used and left (`onToggleMeterStyle`, on a Used/Left
/// reading) and a click on the reset between countdown and exact time (`onToggleResetDisplay`). A row
/// under the pointer draws as it does at rest; resting the pointer on the bar, the value or the reset
/// opens a tooltip with the one figure the row doesn't show (where the pace lands at reset, the other
/// reading, the other format). The Limit Resets row's count is the one hover that changes the row: the
/// figure lights on a quaternary chip the moment the pointer arrives, the resets timeline opens below
/// it after the hover dwell, anchored on the figure, and closes once the pointer has left both the
/// figure and the popover (with a short grace to travel between them), unless a claim in progress pins
/// it open.
struct DashboardLiveRow: View {
    let line: DashboardLine
    /// The Limit Resets row's claim seam, `nil` where resets can't be claimed.
    var resetClaim: ResetClaimService?
    /// Flips the global Used/Left meter style, from the dashboard's data store.
    var onToggleMeterStyle: (() -> Void)?
    /// Flips the global countdown/exact-time reset display, from the dashboard's data store.
    var onToggleResetDisplay: (() -> Void)?

    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var hover = HoverPopoverState()

    var body: some View {
        Group {
            if line.data.resetsAt != nil || !line.data.expiriesAt.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    row(now: context.date)
                }
            } else {
                row(now: Date())
            }
        }
        // A refresh can replace the resets while the popover is open; drop it so it never lingers over a
        // stale timeline, unless the claim flow pinned it (the claim's own refresh changes the resets).
        .onChange(of: line.data.expiriesAt) { _, _ in
            if !hover.isPinned { hover.dismiss() }
        }
        .onDisappear { hover.dismiss() }
    }

    private func row(now: Date) -> some View {
        DashboardMetricRow(
            model: line.data.dashboardRow(now: now),
            onToggleMeterStyle: line.data.hasMeterStyleToggle ? onToggleMeterStyle : nil,
            onToggleResetDisplay: onToggleResetDisplay,
            paceTooltip: line.data.paceTooltip(now: now),
            valueTooltip: line.data.meterStyleTooltip,
            resetTooltip: line.data.resetTooltip(now: now),
            figure: line.data.showsResetExpiries ? { AnyView(resetsTrigger($0)) } : { $0 }
        )
    }

    /// The Limit Resets count as the popover's trigger and anchor. The chip lights while the pointer is
    /// on the figure or the popover is open, so the figure reads as the popover's source.
    private func resetsTrigger(_ figure: AnyView) -> some View {
        let lit = hover.overInline || hover.isPresented
        return figure
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
                    .opacity(lit ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: lit)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
            }
            .motionAwareHoverPopover(
                isPresented: Binding(
                    get: { hover.isPresented },
                    // A click-outside dismiss removes the detail view without an `.ended` hover event,
                    // so a plain assignment would strand the hover bookkeeping and block future hides.
                    set: { if !$0 { hover.dismiss() } }
                ),
                reduceAnimations: reduceAnimations
            ) {
                RateLimitResetsDetail(
                    count: line.data.resetCreditCount,
                    expiries: line.data.expiriesAt,
                    onHoverChange: { inside in hover.detailHover(inside) },
                    onPinChange: { pinned in hover.setPinned(pinned) },
                    claim: resetClaim.flatMap { service in
                        service.isClaimable ? { expiry, redeemRequestID in
                            await service.claim(creditExpiringAt: expiry, redeemRequestID: redeemRequestID)
                        } : nil
                    },
                    confirmDetail: resetClaim?.confirmDetail
                )
            }
    }
}
