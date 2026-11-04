import SwiftUI

struct DashboardLiveRow: View {
    let line: DashboardLine
    var resetClaim: ResetClaimService?
    var breakdown: UsageBreakdown?
    var accountStatus = AccountStatus()
    var snapshotDate: Date?
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?

    @Environment(\.reduceAnimations) private var reduceAnimations
    @Environment(\.colorScheme) private var colorScheme
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
        if case let .window(window, _, _) = line.descriptor.historyRow {
            return {
                AnyView(hoverTrigger($0) {
                    UsageBreakdownDetail(
                        content: breakdown.map(UsageBreakdownDetail.Content.reported)
                            ?? .saved(window, figures: line.data.unboundedFigures, status: accountStatus, date: snapshotDate),
                        provider: provider,
                        animates: !reduceAnimations,
                        onCopy: copy,
                        onHoverChange: { inside in hover.detailHover(inside) }
                    )
                })
            }
        }
        return { $0 }
    }

    private var provider: Provider {
        Provider(id: line.descriptor.providerID, kind: line.descriptor.providerKind)
    }

    private func copy(_ breakdown: UsageBreakdown, showing figure: ModelFigure) -> Bool {
        let card = UsageBreakdownShareCard(provider: provider, breakdown: breakdown, figure: figure, appearance: colorScheme)
        return ShareCardRenderer.copy(card, named: line.descriptor.id)
    }

    private func hoverTrigger<Detail: View>(_ figure: AnyView, @ViewBuilder detail: @escaping () -> Detail) -> some View {
        let lit = hover.overInline || hover.isPresented
        return Button(action: hover.openDetails) { figure }
            .buttonStyle(.plain)
            .accessibilityHint("Show details")
            .hoverHighlight(lit)
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
            showsActions: hover.openedExplicitly,
            onHoverChange: { inside in hover.detailHover(inside) },
            onPinChange: { pinned in hover.setPinned(pinned) },
            claim: resetClaim.flatMap { service in
                service.isClaimable ? { expiry, redeemRequestID in
                    await service.claim(creditExpiringAt: expiry, redeemRequestID: redeemRequestID)
                } : nil
            },
            confirmDetail: resetClaim?.confirmDetail,
            windowResets: resetClaim?.windowResets ?? [],
            claimWindowReset: resetClaim.map { service in
                { reset, requestID in await service.claim(reset, requestID: requestID) }
            }
        )
    }
}
