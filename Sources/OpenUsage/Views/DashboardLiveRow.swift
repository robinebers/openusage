import SwiftUI

struct DashboardLiveRow: View {
    let line: DashboardLine
    var resetClaim: ResetClaimService?
    var breakdown: UsageBreakdown?
    var onToggleMeterStyle: (() -> Void)?
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
            figure: figure
        )
    }

    private var figure: (AnyView) -> AnyView {
        if line.data.showsResetExpiries { return { AnyView(hoverTrigger($0) { resetsDetail }) } }
        if let breakdown {
            return {
                AnyView(hoverTrigger($0) {
                    UsageBreakdownDetail(
                        breakdown: breakdown,
                        providerName: line.descriptor.providerKind.displayName,
                        onHoverChange: { inside in hover.detailHover(inside) }
                    )
                })
            }
        }
        return { $0 }
    }

    private func hoverTrigger<Detail: View>(_ figure: AnyView, @ViewBuilder detail: @escaping () -> Detail) -> some View {
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
                reduceAnimations: reduceAnimations,
                content: detail
            )
    }

    private var resetsDetail: some View {
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
